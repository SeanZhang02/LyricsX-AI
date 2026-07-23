import AppKit
import Combine
import NaturalLanguage
import UserNotifications
import Regex
import OpenCC
import MusicPlayer
import LyricsXFoundation

class AppController: NSObject {
    static let shared = AppController()

    var lyricsManager: LyricsProvider

    @Published var currentLyrics: Lyrics? {
        willSet {
            willChangeValue(forKey: "lyricsOffset")
            currentLineIndex = nil
        }
        didSet {
            didChangeValue(forKey: "lyricsOffset")
            scheduleCurrentLineCheck()
        }
    }

    @Published var currentLineIndex: Int?

    var searchRequest: LyricsSearchRequest?
    var searchTask: Task<Void, Never>?

    private var cancelBag = Set<AnyCancellable>()

    @objc dynamic var lyricsOffset: Int {
        get {
            return currentLyrics?.offset ?? 0
        }
        set {
            currentLyrics?.offset = newValue
            currentLyrics?.metadata.needsPersist = true
            scheduleCurrentLineCheck()
        }
    }

    private override init() {
        self.lyricsManager = LyricsProviders.Group()
        super.init()
        selectedPlayer.currentTrackWillChange
            .signal()
            .receive(on: DispatchQueue.lyricsDisplay)
            .invoke(AppController.currentTrackChanged, weaklyOn: self)
            .store(in: &cancelBag)
        selectedPlayer.playbackStateWillChange
            .signal()
            .receive(on: DispatchQueue.lyricsDisplay)
            .invoke(AppController.scheduleCurrentLineCheck, weaklyOn: self)
            .store(in: &cancelBag)

        workspaceNC.publisher(for: NSWorkspace.didTerminateApplicationNotification, object: nil)
            .sink { notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let bundleID = application.bundleIdentifier
                if defaults[.launchAndQuitWithPlayer], (selectedPlayer.designatedPlayer as? MusicPlayers.Scriptable)?.playerBundleID == bundleID {
                    NSApplication.shared.terminate(self)
                }
            }.store(in: &cancelBag)
        currentTrackChanged()

        Task {
            try await updateLyricsManager()
        }
    }

    @MainActor
    func updateLyricsManager() async throws {
        let services: [LyricsProviders.Service] = LyricsProviders.Service.noAuthenticationRequiredServices

        var providers: [LyricsProvider] = []
        for service in services {
            providers.append(service.create())
        }

        // Add Musixmatch provider with saved token if available
        if let token = defaults[.musixmatchToken], !token.isEmpty {
            let musixmatchProvider = LyricsProviders.Musixmatch(usertoken: token)
            providers.append(musixmatchProvider)
        }

        lyricsManager = LyricsProviders.Group(providers: providers)
    }

    var currentLineCheckSchedule: Cancellable?

    func scheduleCurrentLineCheck() {
        currentLineCheckSchedule?.cancel()
        guard let lyrics = currentLyrics else {
            return
        }
        let playbackState = MusicPlayers.Selected.shared.playbackState
        let playbackTime = playbackState.time
        let (index, next) = lyrics[playbackTime + lyrics.adjustedTimeDelay]
        if currentLineIndex != index {
            currentLineIndex = index
        }
        if let next = next, playbackState.isPlaying {
            let dt = lyrics.lines[next].position - playbackTime - lyrics.adjustedTimeDelay
            let q = DispatchQueue.lyricsDisplay
            currentLineCheckSchedule = q.schedule(after: q.now.advanced(by: .seconds(dt)), interval: .seconds(42), tolerance: .milliseconds(20)) { [unowned self] in
                self.scheduleCurrentLineCheck()
            }
        }
    }

    func writeToiTunes(overwrite: Bool) {
        guard selectedPlayer.name == .appleMusic,
              let currentLyrics = currentLyrics,
              let sbTrack = selectedPlayer.currentTrack?.originalTrack,
              overwrite || (sbTrack.value(forKey: "lyrics") as! String?)?.isEmpty != false else {
            return
        }

        let content: String
        if defaults[.writeiTunesConvertToPlainLRC] {
            // For plain LRC export, preserve the legacy LRC formatting but still respect
            // the Chinese conversion setting for consistency with the non-plain branch.
            var legacy = currentLyrics.legacyDescription
            if let converter = ChineseConverter.shared {
                legacy = converter.convert(legacy)
            }
            // Note: translations are intentionally not appended for plain LRC export,
            // even when `writeiTunesWithTranslation` is enabled, to keep the legacy
            // LRC output single-line per timestamp.
            content = legacy
        } else {
            content = currentLyrics.lines.map { line -> String in
                var content = line.content
                if let converter = ChineseConverter.shared {
                    content = converter.convert(content)
                }
                if defaults[.writeiTunesWithTranslation] {
                    // TODO: tagged translation
                    let code = currentLyrics.metadata.translationLanguages.first
                    if var translation = line.attachments[.translation(languageCode: code)] {
                        if let converter = ChineseConverter.shared {
                            translation = converter.convert(translation)
                        }
                        content += "\n" + translation
                    }
                }
                return content
            }.joined(separator: "\n")
        }
        // swiftlint:disable:next force_try
        let regex = Regex(#"\n{3,}"#)
        let replaced = content.replacingMatches(of: regex, with: "\n\n")
        sbTrack.setValue(replaced, forKey: "lyrics")
    }

    func currentTrackChanged() {
        if currentLyrics?.metadata.needsPersist == true {
            currentLyrics?.persist()
        }
        currentLyrics = nil
        currentLineIndex = nil
        searchTask?.cancel()
        guard let track = selectedPlayer.currentTrack else {
            return
        }
        // FIXME: deal with optional value
        let title = track.title ?? ""
        let artist = track.artist ?? ""

        guard !defaults[.noSearchingTrackIds].contains(track.id) else {
            return
        }

        var candidateLyricsURL: [(URL, Bool, Bool)] = [] // (fileURL, isSecurityScoped, needsSearching)

        if defaults[.loadLyricsBesideTrack] {
            if let embeddedLyrics = track.lyrics, !embeddedLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let lyrics = Lyrics(embeddedLyrics) {
                    if lyrics.metadata.title == nil || lyrics.metadata.title?.isEmpty == true {
                        lyrics.metadata.title = title
                    }
                    if lyrics.metadata.artist == nil || lyrics.metadata.artist?.isEmpty == true {
                        lyrics.metadata.artist = artist
                    }
                    lyrics.filtrate()
                    lyrics.recognizeLanguage()
                    currentLyrics = lyrics
                    AITranslationService.shared.translateIfNeeded(lyrics)
                    return
                }
            }
            if let fileName = track.localFileURL?.deletingPathExtension() {
                candidateLyricsURL += [
                    (fileName.appendingPathExtension("lrcx"), false, false),
                    (fileName.appendingPathExtension("lrc"), false, false),
                ]
            }
        }

        let (url, security) = defaults.lyricsSavingPath()
        let titleForReading = title.replacingOccurrences(of: "/", with: ":")
        let artistForReading = artist.replacingOccurrences(of: "/", with: ":")
        let fileName = url.appendingPathComponent("\(titleForReading) - \(artistForReading)")
        candidateLyricsURL += [
            (fileName.appendingPathExtension("lrcx"), security, false),
            (fileName.appendingPathExtension("lrc"), security, true),
        ]

        for (url, security, needsSearching) in candidateLyricsURL {
            if security {
                guard url.startAccessingSecurityScopedResource() else {
                    continue
                }
            }
            defer {
                if security {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            if let lrcContents = try? String(contentsOf: url, encoding: String.Encoding.utf8),
               let lyrics = Lyrics(lrcContents) {
                lyrics.metadata.localURL = url
                lyrics.metadata.title = title
                lyrics.metadata.artist = artist
                lyrics.filtrate()
                lyrics.recognizeLanguage()
                currentLyrics = lyrics
                AITranslationService.shared.translateIfNeeded(lyrics)
                if needsSearching {
                    break
                } else {
                    return
                }
            }
        }

        if let album = track.album, defaults[.noSearchingAlbumNames].contains(album) {
            return
        }

        let duration = track.duration ?? 0
        let request = LyricsSearchRequest(searchTerm: .info(title: title, artist: artist), duration: duration, limit: 5)
        searchRequest = request
        searchTask = Task { @MainActor in
            do {
                // Accept the first arrived lyrics immediately,
                // but keep collecting for a short window to allow higher-priority providers,
                // which might be slower, to replace it.
                let window = defaults[.lyricsPriorityWindow] ?? 5 // seconds
                var firstReceived = false
                var collectionStart: Date?

                for try await lyrics in lyricsManager.lyrics(for: request) {
                    if !firstReceived {
                        lyricsReceived(lyrics: lyrics)
                        if let current = currentLyrics, current === lyrics {
                            firstReceived = true
                            collectionStart = Date()
                        }
                        continue
                    }

                    if let start = collectionStart,
                       Date().timeIntervalSince(start) <= window {
                        lyricsReceived(lyrics: lyrics)
                        continue
                    } else {
                        // window expired
                        break
                    }
                }

                if defaults[.writeToiTunesAutomatically] {
                    writeToiTunes(overwrite: true)
                }
                AITranslationService.shared.translateIfNeeded(currentLyrics)
            } catch is CancellationError {
                // Search was cancelled due to track change
            } catch {
                print("Failed to fetch lyrics: \(error.localizedDescription)")
            }
        }
    }

    // MARK: LyricsSourceDelegate

    func lyricsReceived(lyrics: Lyrics) {
        guard let req = searchRequest,
              lyrics.metadata.request == req,
              let track = selectedPlayer.currentTrack else {
            return
        }
        if defaults[.strictSearchEnabled], !lyrics.isMatched() {
            return
        }
        if let current = currentLyrics, !lyricsHasHigherPriority(lyrics, over: current) {
            return
        }

        lyrics.associateWithTrack(track)
        lyrics.filtrate()
        lyrics.recognizeLanguage()
        lyrics.metadata.needsPersist = true
        currentLyrics = lyrics
    }
}

extension AppController {
    func importLyrics(_ lyricsString: String) throws {
        guard let lrc = Lyrics(lyricsString) else {
            let errorInfo = [
                NSLocalizedDescriptionKey: "Invalid lyric file",
                NSLocalizedRecoverySuggestionErrorKey: "Please try another one.",
            ]
            let error = NSError(domain: lyricsXErrorDomain, code: 0, userInfo: errorInfo)
            throw error
        }
        guard let track = selectedPlayer.currentTrack else {
            let errorInfo = [
                NSLocalizedDescriptionKey: "No music playing",
                NSLocalizedRecoverySuggestionErrorKey: "Play a music and try again.",
            ]
            let error = NSError(domain: lyricsXErrorDomain, code: 0, userInfo: errorInfo)
            throw error
        }
        lrc.metadata.title = track.title
        lrc.metadata.artist = track.artist
        lrc.filtrate()
        lrc.recognizeLanguage()
        lrc.metadata.needsPersist = true
        currentLyrics = lrc
        AITranslationService.shared.translateIfNeeded(lrc)
        if let index = defaults[.noSearchingTrackIds].firstIndex(of: track.id) {
            defaults[.noSearchingTrackIds].remove(at: index)
        }
        if let index = defaults[.noSearchingAlbumNames].firstIndex(of: track.album ?? "") {
            defaults[.noSearchingAlbumNames].remove(at: index)
        }
    }
}

// MARK: - AI Translation

private extension Lyrics.Metadata.Key {
    static var aiTranslationAttempted = Lyrics.Metadata.Key("aiTranslationAttempted")
}

/// 歌词 AI 翻译中间件: 歌词加载后若无目标语言翻译, 调用 OpenAI 兼容接口逐行翻译,
/// 以 [tr:lang] 附件形式写入歌词行并持久化到本地 lrcx 文件。
class AITranslationService {

    static let shared = AITranslationService()

    /// 是否有翻译任务进行中 (菜单栏据此显示"翻译中…")
    private(set) var isTranslating = false

    private let queue = DispatchQueue(label: "com.JH.LyricsX.aiTranslation", qos: .utility)

    /// 发送系统通知
    private func notify(_ title: String, _ body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    /// 菜单手动触发: 无视自动开关与"已尝试"标记, 每种跳过原因都给出通知反馈
    func translateNow(_ lyrics: Lyrics?) {
        guard !defaults[.aiTranslationBaseURL].isEmpty,
              !defaults[.aiTranslationAPIKey].isEmpty,
              !defaults[.aiTranslationModel].isEmpty else {
            notify("AI 翻译未配置", "请在 偏好设置 → 通用 填写接口地址、API Key 和模型")
            return
        }
        guard let lyrics = lyrics else { return }
        guard !lyrics.metadata.hasTranslation else {
            notify("无需翻译", "这首歌已经有翻译了")
            return
        }
        queue.async {
            lyrics.metadata.data[.aiTranslationAttempted] = true
            guard self.isTranslatable(lyrics) else {
                self.notify("无需翻译", "歌词本身已是目标语言, 或太短(纯音乐)")
                return
            }
            log("AI translation (manual) started for \(lyrics.metadata.title ?? "?")")
            self.translate(lyrics)
        }
    }

    func translateIfNeeded(_ lyrics: Lyrics?) {
        guard defaults[.aiTranslationEnabled],
              !defaults[.aiTranslationBaseURL].isEmpty,
              !defaults[.aiTranslationAPIKey].isEmpty,
              !defaults[.aiTranslationModel].isEmpty,
              let lyrics = lyrics,
              !lyrics.metadata.hasTranslation else {
            return
        }
        queue.async {
            guard lyrics.metadata.data[.aiTranslationAttempted] as? Bool != true else { return }
            lyrics.metadata.data[.aiTranslationAttempted] = true
            guard self.isTranslatable(lyrics) else { return }
            log("AI translation started for \(lyrics.metadata.title ?? "?")")
            self.translate(lyrics)
        }
    }

    // MARK: 语言判定

    /// 用系统 NaturalLanguage 框架离线识别源语言(无网络、无第三方依赖):
    /// 歌词本身已是目标语言(如中文歌 → 中译中)或太短(纯音乐)时跳过, 不调用 LLM。
    private func isTranslatable(_ lyrics: Lyrics) -> Bool {
        let contents = lyrics.lines.map(\.content).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard contents.count >= 4 else { return false }

        let target = defaults[.aiTranslationTargetLanguage].isEmpty
            ? "zh-Hans" : defaults[.aiTranslationTargetLanguage]

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(contents.joined(separator: "\n"))
        // 识别不出(文本太短/多语混排)时偏向翻译 —— 逐行 prompt 会把已是目标语言的行输出「编号|-」兜底
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        let targetConfidence = hypotheses.first { languageMatches($0.key.rawValue, target) }?.value ?? 0
        // 目标语言置信度足够高 → 判定歌词本身已是目标语言, 跳过翻译
        return targetConfidence < 0.65
    }

    /// 按 BCP-47 主子标签比较语言代码: "zh" ~ "zh-Hans" ~ "zh-Hant", "en" ~ "en-US"
    private func languageMatches(_ a: String, _ b: String) -> Bool {
        func primary(_ code: String) -> String {
            (code.split(separator: "-").first.map(String.init) ?? code).lowercased()
        }
        return primary(a) == primary(b)
    }

    // MARK: 翻译流程

    private func translate(_ lyrics: Lyrics) {
        let targetCode = defaults[.aiTranslationTargetLanguage].isEmpty ? "zh-Hans" : defaults[.aiTranslationTargetLanguage]
        let tag = LyricsLine.Attachments.Tag.translation(languageCode: targetCode)

        var indices: [Int] = []
        for (i, line) in lyrics.lines.enumerated() {
            let content = line.content.trimmingCharacters(in: .whitespaces)
            if !content.isEmpty, line.attachments[tag] == nil {
                indices.append(i)
            }
        }
        guard !indices.isEmpty else { return }

        let title = [lyrics.metadata.title, lyrics.metadata.artist].compactMap { $0 }.joined(separator: " - ")
        isTranslating = true
        defer { isTranslating = false }
        var results: [Int: String] = [:]
        let chunkSize = 100
        var start = 0
        while start < indices.count {
            let chunk = Array(indices[start ..< min(start + chunkSize, indices.count)])
            guard let answer = requestTranslation(
                of: chunk.map { lyrics.lines[$0].content },
                title: title,
                targetCode: targetCode
            ) else {
                log("AI translation request failed for \(title)")
                notify("AI 翻译失败", "《\(title)》网络请求失败, 稍后可从菜单重试")
                return
            }
            parseAnswer(answer, chunk: chunk, lyrics: lyrics, into: &results)
            start += chunkSize
        }
        // 覆盖率过低视为失败, 防止错位的结果污染歌词文件
        guard results.count * 2 >= indices.count else {
            log("AI translation coverage too low for \(title): \(results.count)/\(indices.count)")
            notify("AI 翻译失败", "《\(title)》译文校验未通过, 已放弃本次结果")
            return
        }

        DispatchQueue.lyricsDisplay.async {
            for (i, text) in results {
                lyrics.lines[i].attachments[tag] = text
            }
            lyrics.metadata.attachmentTags.insert(tag)
            lyrics.metadata.needsPersist = true
            lyrics.persist()
            let appController = AppController.shared
            if appController.currentLyrics === lyrics {
                // 触发一次行刷新, 让当前行立即显示译文
                appController.currentLineIndex = nil
                appController.scheduleCurrentLineCheck()
            }
            log("AI translation finished for \(title): \(results.count)/\(indices.count) lines")
            self.notify("AI 翻译完成", "《\(title)》已翻译 \(results.count) 行, 歌词已实时更新")
        }
    }

    private func languageName(of code: String) -> String {
        switch code {
        case "zh-Hans": return "简体中文"
        case "zh-Hant": return "繁體中文"
        case let c where c.hasPrefix("zh"): return "简体中文"
        case "en": return "English"
        case "ja": return "日本語"
        default: return code
        }
    }

    private func buildPrompt(of contents: [String], title: String, targetCode: String) -> String {
        let target = languageName(of: targetCode)
        let numbered = contents.enumerated().map { "\($0.offset + 1)|\($0.element)" }.joined(separator: "\n")
        return """
        你是一位资深的歌词译者。将下面的歌词逐行翻译成\(target)。

        要求:
        - 只输出翻译结果, 每行格式为「编号|译文」, 编号与输入一一对应; 不合并、不拆分、不遗漏、不添加任何解释
        - 先领会整首歌的叙事、情绪与意象, 再逐行落笔, 全篇保持语气与人称一致
        - 传达意境而非字面对应: 译出歌词的画面感与言外之意, 用词凝练, 有中文歌词的韵律与诗意
        - 俚语、双关与文化梗用贴切的中文意象转译, 宁可意译不可生硬直译
        - 如果某行是纯人名/制作信息(词、曲、编曲、制作人等)、无实义拟声词(如 la la la)、或本身已是\(target), 该行输出「编号|-」

        歌曲: \(title)

        \(numbered)
        """
    }

    private func requestTranslation(of contents: [String], title: String, targetCode: String) -> String? {
        var base = defaults[.aiTranslationBaseURL]
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else { return nil }
        let prompt = buildPrompt(of: contents, title: title, targetCode: targetCode)
        let body: [String: Any] = [
            "model": defaults[.aiTranslationModel],
            "messages": [["role": "user", "content": prompt]],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + defaults[.aiTranslationAPIKey], forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        for attempt in 1...2 {
            if let answer = performRequest(request) {
                return answer
            }
            if attempt == 1 {
                Thread.sleep(forTimeInterval: 5)
            }
        }
        return nil
    }

    private func performRequest(_ request: URLRequest) -> String? {
        var answer: String?
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                log("AI translation network error: \(error.localizedDescription)")
                return
            }
            guard let data = data else { return }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                log("AI translation HTTP \(status): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
                return
            }
            let choices = object["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            answer = message?["content"] as? String
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 130) == .timedOut {
            task.cancel()
            log("AI translation request timed out")
        }
        return answer
    }

    private func parseAnswer(_ answer: String, chunk: [Int], lyrics: Lyrics, into results: inout [Int: String]) {
        for raw in answer.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let sep = line.firstIndex(where: { $0 == "|" || $0 == "｜" }),
                  let n = Int(line[..<sep].trimmingCharacters(in: .whitespaces)),
                  n >= 1, n <= chunk.count else {
                continue
            }
            let text = String(line[line.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text != "-" else { continue }
            let lineIndex = chunk[n - 1]
            if text != lyrics.lines[lineIndex].content.trimmingCharacters(in: .whitespaces) {
                results[lineIndex] = text
            }
        }
    }
}
