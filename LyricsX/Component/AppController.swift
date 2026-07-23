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
        // Musixmatch(已含在 noAuthenticationRequiredServices)每次请求从 AuthenticationManagerStore 读 token。
        // 手填优先, 否则用自动拉取并缓存的 token; 先注入本地缓存(快)压首曲竞态, 再后台刷新。
        let manual = defaults[.musixmatchToken]
        let cached = (manual?.isEmpty == false) ? manual : defaults[.musixmatchAutoToken]
        if let token = cached, !token.isEmpty {
            await AuthenticationManagerStore.shared.setMusixmatchToken(token)
        }

        let services = LyricsProviders.Service.noAuthenticationRequiredServices
        lyricsManager = LyricsProviders.Group(providers: services.map { $0.create() })

        // 手填为空时后台刷新自动 token(共享 trial token 会限流失效, 每次启动重拉一次)
        if manual?.isEmpty != false {
            refreshMusixmatchAutoToken()
        }
    }

    /// 后台从 token.get 拉一个 Musixmatch usertoken, 成功则覆盖缓存并注入 store; 失败保留旧缓存。
    private func refreshMusixmatchAutoToken() {
        Task {
            guard let token = await MusixmatchToken.fetch() else { return }
            defaults[.musixmatchAutoToken] = token
            // 拉取期间用户可能刚在 Lab 粘了手填 token, 手填优先, 别覆盖
            guard defaults[.musixmatchToken]?.isEmpty != false else { return }
            await AuthenticationManagerStore.shared.setMusixmatchToken(token)
        }
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
        // 清洗查询串(去 (Live)/[feat…] 等版本噪声, 提升召回); 原始 title/artist 不变(缓存文件名 + 匹配门要用)
        let request = LyricsSearchRequest(
            searchTerm: .info(title: cleanSearchTitle(title), artist: cleanSearchArtist(artist)),
            duration: duration, limit: 5
        )
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
                    // 不覆盖已有 Apple 歌词, 保住 Apple Music 的逐词同步(仅当曲目无歌词时写)
                    writeToiTunes(overwrite: false)
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
        // 匹配门:拒绝与查询完全不相干的候选(治西语→日语粗错), 放在落盘/写 iTunes/发布之前
        guard passesMatchFloor(lyrics, request: req, rawTitle: track.title ?? "", rawArtist: track.artist ?? "", trackDuration: track.duration) else {
            return
        }
        if let current = currentLyrics, !lyricsHasHigherPriority(lyrics, over: current, trackAlbum: track.album) {
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

    /// 主模型硬失败时依次尝试的备选(同一 OpenRouter key 只换 model 字段)
    private let fallbackModels = ["anthropic/claude-sonnet-5", "deepseek/deepseek-chat-v3.1"]

    private enum RequestOutcome {
        case success(String)   // 仅 "HTTP 200 且 content 非空"
        case authFailure       // HTTP 401 / 403
        case hardFailure       // 网络错误 / 超时 / 其它非 200 / 空 content / JSON 解析失败
    }

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

    /// 菜单手动触发: 无视自动开关/已尝试标记/已有翻译, 强制覆盖重译。
    func translateNow(_ lyrics: Lyrics?) {
        guard !defaults[.aiTranslationBaseURL].isEmpty,
              !defaults[.aiTranslationAPIKey].isEmpty,
              !defaults[.aiTranslationModel].isEmpty else {
            notify("AI 翻译未配置", "请在 偏好设置 → 通用 填写接口地址、API Key 和模型")
            return
        }
        guard let lyrics = lyrics else { return }
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
              translationCoverage(lyrics) < 0.5 else {   // 部分翻译(<50%)也重译补全; 全译则跳过
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

        let target = targetLanguageCode

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

    private var targetLanguageCode: String {
        defaults[.aiTranslationTargetLanguage].isEmpty ? "zh-Hans" : defaults[.aiTranslationTargetLanguage]
    }

    /// 阈值 0.5 必须 ≤ persist 门控比例(results*2>=indices), 否则落盘成功的歌下次加载仍 <阈值、被反复重译。
    private func translationCoverage(_ lyrics: Lyrics) -> Double {
        let tag = LyricsLine.Attachments.Tag.translation(languageCode: targetLanguageCode)
        let content = lyrics.lines.filter { !$0.content.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !content.isEmpty else { return 1 }
        return Double(content.filter { $0.attachments[tag] != nil }.count) / Double(content.count)
    }

    // MARK: 翻译流程

    private func translate(_ lyrics: Lyrics) {
        let targetCode = targetLanguageCode
        let tag = LyricsLine.Attachments.Tag.translation(languageCode: targetCode)

        // 收集全部非空正文行(覆盖重译: 新译同 tag 直接盖旧值, 部分翻译得以补全)
        var indices: [Int] = []
        for (i, line) in lyrics.lines.enumerated() where !line.content.trimmingCharacters(in: .whitespaces).isEmpty {
            indices.append(i)
        }
        guard !indices.isEmpty else { return }

        let title = [lyrics.metadata.title, lyrics.metadata.artist].compactMap { $0 }.joined(separator: " - ")
        isTranslating = true
        defer { isTranslating = false }
        var results: [Int: String] = [:]
        var usedModel = ""
        let chunkSize = 100
        var start = 0
        while start < indices.count {
            let chunk = Array(indices[start ..< min(start + chunkSize, indices.count)])
            guard let (answer, model) = requestTranslation(
                of: chunk.map { lyrics.lines[$0].content },
                title: title,
                targetCode: targetCode
            ) else {
                // requestTranslation 已按失败类型发过通知(key 无效 / 接口地址无效 / 网络请求失败), 此处直接放弃
                log("AI translation request failed for \(title)")
                return
            }
            usedModel = model
            parseAnswer(answer, chunk: chunk, lyrics: lyrics, into: &results)
            start += chunkSize
        }
        // 覆盖率过低视为失败, 防止错位的结果污染歌词文件
        guard results.count * 2 >= indices.count else {
            log("AI translation coverage too low for \(title): \(results.count)/\(indices.count)")
            notify("AI 翻译失败", "《\(title)》译文校验未通过, 已放弃本次结果")
            return
        }

        let modelName = shortModelName(usedModel)
        DispatchQueue.lyricsDisplay.async {
            // H1 copy-then-publish: 不原地 mutate 共享 Lyrics(避免 data race), 构造新实例并重新发布,
            // 让所有 $currentLyrics 订阅者(含 HUD 歌词窗口)重建并显示译文。
            _ = lyrics.quality                          // 先固化 quality 缓存, 防译文 attachment 抬高择优分
            var newLines = lyrics.lines
            // 剥离非目标语的旧译 tag, 否则同行双 translation tag 会让显示层随机选到哪种语言
            let staleTranslations = lyrics.metadata.attachmentTags.filter { $0.isTranslation && $0 != tag }
            for i in newLines.indices {
                staleTranslations.forEach { newLines[i].attachments[$0] = nil }
                if let text = results[i] { newLines[i].attachments[tag] = text }
            }
            let newLyrics = Lyrics(lines: newLines, idTags: lyrics.idTags, metadata: lyrics.metadata)
            // 注: init 会从 newLines 重算 metadata.attachmentTags(已含译文 tag), 无需手动 insert
            newLyrics.metadata.needsPersist = true
            newLyrics.persist()
            if AppController.shared.currentLyrics === lyrics {
                AppController.shared.currentLyrics = newLyrics   // 重新发布 → 显示层重建带译文
            }
            log("AI translation finished for \(title): \(results.count)/\(indices.count) lines via \(modelName)")
            self.notify("AI 翻译完成", "《\(title)》已用 \(modelName) 翻译 \(results.count) 行, 歌词已实时更新")
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

    private func shortModelName(_ model: String) -> String {
        switch model {
        case "anthropic/claude-opus-4.8": return "opus4.8"
        case "anthropic/claude-sonnet-5": return "sonnet5"
        case "deepseek/deepseek-chat-v3.1": return "deepseek"
        default: return model.split(separator: "/").last.map(String.init) ?? model
        }
    }

    private func buildPrompt(of contents: [String], title: String, targetCode: String) -> String {
        let target = languageName(of: targetCode)
        let numbered = contents.enumerated().map { "\($0.offset + 1)|\($0.element)" }.joined(separator: "\n")
        return """
        你是一位歌词文学译者,精通多语言诗歌与歌词翻译。任务:把用户本地播放器歌词文件中的歌词翻译成\(target),仅为个人查看生成;译文将随音乐在歌词界面逐行滚动显示,每行独立成句呈现。

        ## 语言规则
        - 只翻译非\(target)歌词,统一译为\(target)。若某行本身已是\(target),按"无需翻译"处理。

        ## 翻译流程
        先通读整首歌词,确定主题、情绪、叙事视角和语体基调(民谣、抒情、摇滚、说唱;口语或典雅),再逐行翻译。全篇人称、语气、语体保持同一基调,不得中途漂移:口语译口语,典雅译典雅,俚语找\(target)里同等鲜活的对应,不磨平也不加戏。

        ## 翻译原则(按优先级)
        1. 忠实是底线:意译只能换"说法",不能换"意思"。不引入原文既无明说也无暗示的新意象、新信息,不丢弃原文的具体意象和实词;即使你记忆中这首歌有别的版本,也严格以输入文本为准,不补全、不纠正、不替换。
        2. 行内自足:每行译文只承载该行原文的内容,不把语义挪到相邻行,不合并、不拆分、不增删行。上下行语法相连时可让译文读来连贯,但内容归属不变。
        3. 意象落地:保留原文的隐喻与画面,用\(target)里自然地道的搭配落笔;逐字直译若搭配生硬(如"叹息溢出""笑容击落我心"),换成意象等值、搭配自然的说法。排比、反复、双关、同源词等修辞,用\(target)的等效手法再现。
        4. 凝练与节奏:歌词是诗,以短为美。删去一切可省的虚词与冗余——"的/了/着/吧"、指示词"这/那"、可省的量词与代词;\(target)为中文时主语能省则省,优先短句与对称结构(如四字组、前后句呼应),让每行有歌的气口,译文不比原文行更啰嗦。
        5. 留白:不替听者把话说尽——不补因果连接词,不把暗示译成直陈,允许意象并置与跳跃,像原文一样留余味。
        6. 语气词纪律:不逐字搬运源语的句末语气词(如日语 ね/よ/の),"呢/吧/啊"只在情绪确需处偶用;行内引语自然融入句子,不用冒号加引号的对白格式;不用网络流行语,除非原文本身即是俚语说唱。
        7. 具象行贴直译,抒情行可意译:名词性画面行(景物、物件、罗列)贴近原文保留意象与简洁;直抒胸臆的情绪行可稍作意译换取自然,仍受第 1 条约束。
        8. 重复段一致:原文完全相同的行,译文必须逐字相同;排比与句首反复保持同一句式。
        9. 文化负载词:不可译概念(如 saudade、ojalá)就近选最贴切的\(target)表达;宗教/神话/地名/人名用通行译名,无则保留原文。

        ## 输出格式(严格遵守)
        逐行输出「编号|译文」:编号照抄输入、一一对应、不改顺序;译文单行、不含换行、不含方括号 [ ]、不含竖线 |;拟声词/ad-lib、纯制作信息行、本身已是\(target)的行输出「编号|-」;除这些行外不输出任何解释、前言、空行或代码块。

        ## 输入
        歌名:\(title)(仅供理解语境,不作翻译依据)
        歌词:
        \(numbered)
        """
    }

    /// 遍历 [主模型 + 备选] 链: 硬失败换下一个; 401/403 立即中止提示 key 错; 成功返回译文 + 实际用的模型。
    private func requestTranslation(of contents: [String], title: String, targetCode: String) -> (answer: String, model: String)? {
        var base = defaults[.aiTranslationBaseURL]
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else {
            notify("AI 翻译失败", "接口地址无效, 请检查 偏好设置 → 通用")
            return nil
        }
        let prompt = buildPrompt(of: contents, title: title, targetCode: targetCode)
        let key = defaults[.aiTranslationAPIKey]

        let primary = defaults[.aiTranslationModel].isEmpty ? "anthropic/claude-opus-4.8" : defaults[.aiTranslationModel]
        let chain = [primary] + fallbackModels.filter { $0 != primary }

        for model in chain {
            let body: [String: Any] = [
                "model": model,
                "temperature": 0,
                "messages": [["role": "user", "content": prompt]],
            ]
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            switch performRequest(request) {
            case .success(let answer):
                return (answer, model)
            case .authFailure:
                notify("AI 翻译失败", "API Key 无效, 请检查 偏好设置 → 通用")
                return nil
            case .hardFailure:
                log("AI translation hard failure on \(model) for \(title), trying next")
                continue
            }
        }
        notify("AI 翻译失败", "《\(title)》网络请求失败, 稍后可从菜单重试")
        return nil
    }

    private func performRequest(_ request: URLRequest) -> RequestOutcome {
        var outcome: RequestOutcome = .hardFailure   // 兜底: error / 无响应 / JSON 解析失败 / 超时 都落这
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                log("AI translation network error: \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse else { return }
            // 先判状态码, 早于 JSON 解析: 401/403 无条件视为 key 无效(其 body 常是非 JSON 的 HTML)
            if http.statusCode == 401 || http.statusCode == 403 {
                outcome = .authFailure
                return
            }
            guard http.statusCode == 200, let data = data else {
                let preview = data.flatMap { String(data: $0, encoding: .utf8) }?.prefix(200) ?? ""
                log("AI translation HTTP \(http.statusCode): \(preview)")
                return
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let choices = object["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            if let content = message?["content"] as? String,
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                outcome = .success(content)
            }
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 130) == .timedOut {
            task.cancel()
            log("AI translation request timed out")
        }
        return outcome
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
