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
        // Musixmatch (already in noAuthenticationRequiredServices) reads its token from AuthenticationManagerStore per request.
        // Manual token wins; otherwise use the auto-fetched cached token. Inject the cache first (fast, avoids a first-song race), then refresh in the background.
        let manual = defaults[.musixmatchToken]
        let cached = (manual?.isEmpty == false) ? manual : defaults[.musixmatchAutoToken]
        if let token = cached, !token.isEmpty {
            await AuthenticationManagerStore.shared.setMusixmatchToken(token)
        }

        let services = LyricsProviders.Service.noAuthenticationRequiredServices
        lyricsManager = LyricsProviders.Group(providers: services.map { $0.create() })

        // With no manual token, refresh the auto token in the background (the shared trial token gets rate-limited; re-fetch once per launch).
        if manual?.isEmpty != false {
            refreshMusixmatchAutoToken()
        }
    }

    /// Fetch a Musixmatch usertoken from token.get in the background; on success overwrite the cache and inject the store, on failure keep the old cache.
    private func refreshMusixmatchAutoToken() {
        Task {
            guard let token = await MusixmatchToken.fetch() else { return }
            defaults[.musixmatchAutoToken] = token
            // The user may have pasted a manual token in Lab while fetching; the manual token wins, don't overwrite.
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
        // Clean the query (drop (Live)/[feat…] version noise) to improve recall; keep the raw title/artist (used for the cache file name and the match floor).
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
                    // Don't overwrite existing Apple lyrics — preserves Apple Music's word-by-word sync (only write when the track has none).
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
        // Match floor: reject candidates unrelated to the query (fixes e.g. Spanish -> Japanese), before persist / iTunes write / publish.
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

/// AI lyrics translation service: once lyrics load without a target-language translation, translate line by line via an OpenAI-compatible API,
/// writing each line as a [tr:lang] attachment and persisting to the local lrcx file.
class AITranslationService {

    static let shared = AITranslationService()

    /// Whether a translation task is running (the menu bar shows "translating..." based on this).
    private(set) var isTranslating = false

    private let queue = DispatchQueue(label: "com.JH.LyricsX.aiTranslation", qos: .utility)

    /// Fallbacks tried in order when the primary model hard-fails (same OpenRouter key, only the model field changes).
    private let fallbackModels = ["anthropic/claude-sonnet-5", "deepseek/deepseek-chat-v3.1"]

    private enum RequestOutcome {
        case success(String)   // only "HTTP 200 with non-empty content"
        case authFailure       // HTTP 401 / 403
        case hardFailure       // network error / timeout / other non-200 / empty content / JSON parse failure
    }

    /// Post a system notification.
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

    /// Manual menu trigger: ignores the auto toggle / attempted flag / existing translation and force re-translates (overwrite).
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
              translationCoverage(lyrics) < 0.5 else {   // re-translate partial (<50%) to complete it; skip if fully translated
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

    // MARK: Language detection

    /// Detect the source language offline with the system NaturalLanguage framework (no network, no third-party deps):
    /// skip (no LLM call) when the lyrics are already the target language (e.g. a Chinese song) or too short (instrumental).
    private func isTranslatable(_ lyrics: Lyrics) -> Bool {
        let contents = lyrics.lines.map(\.content).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard contents.count >= 4 else { return false }

        let target = targetLanguageCode

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(contents.joined(separator: "\n"))
        // When undetectable (too short / mixed languages), lean toward translating — the per-line prompt outputs "n|-" for lines already in the target language.
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        let targetConfidence = hypotheses.first { languageMatches($0.key.rawValue, target) }?.value ?? 0
        // High enough target-language confidence -> treat the lyrics as already in the target language and skip.
        return targetConfidence < 0.65
    }

    /// Compare language codes by BCP-47 primary subtag: "zh" ~ "zh-Hans" ~ "zh-Hant", "en" ~ "en-US".
    private func languageMatches(_ a: String, _ b: String) -> Bool {
        func primary(_ code: String) -> String {
            (code.split(separator: "-").first.map(String.init) ?? code).lowercased()
        }
        return primary(a) == primary(b)
    }

    private var targetLanguageCode: String {
        defaults[.aiTranslationTargetLanguage].isEmpty ? "zh-Hans" : defaults[.aiTranslationTargetLanguage]
    }

    /// The 0.5 threshold must be <= the persist gate ratio (results*2>=indices), or a successfully-persisted song stays below it on the next load and is re-translated every time.
    private func translationCoverage(_ lyrics: Lyrics) -> Double {
        let tag = LyricsLine.Attachments.Tag.translation(languageCode: targetLanguageCode)
        let content = lyrics.lines.filter { !$0.content.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !content.isEmpty else { return 1 }
        return Double(content.filter { $0.attachments[tag] != nil }.count) / Double(content.count)
    }

    // MARK: Translation flow

    private func translate(_ lyrics: Lyrics) {
        let targetCode = targetLanguageCode
        let tag = LyricsLine.Attachments.Tag.translation(languageCode: targetCode)

        // Collect every non-empty content line (overwrite re-translation: new text overwrites the same tag, so partial translations get completed).
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
                // requestTranslation already notified by failure type (invalid key / invalid base URL / network failure); just give up here.
                log("AI translation request failed for \(title)")
                return
            }
            usedModel = model
            parseAnswer(answer, chunk: chunk, lyrics: lyrics, into: &results)
            start += chunkSize
        }
        // Too-low coverage counts as failure, to keep misaligned results from polluting the lyrics file.
        guard results.count * 2 >= indices.count else {
            log("AI translation coverage too low for \(title): \(results.count)/\(indices.count)")
            notify("AI 翻译失败", "《\(title)》译文校验未通过, 已放弃本次结果")
            return
        }

        let modelName = shortModelName(usedModel)
        DispatchQueue.lyricsDisplay.async {
            // H1 copy-then-publish: don't mutate the shared Lyrics in place (avoids a data race); build a new instance and republish
            // so every $currentLyrics subscriber (incl. the HUD window) rebuilds and shows the translation.
            _ = lyrics.quality                          // freeze the quality cache first so the translation attachment can't inflate the ranking score
            var newLines = lyrics.lines
            // Strip stale non-target translation tags, otherwise two translation tags on a line make the display layer pick a language at random.
            let staleTranslations = lyrics.metadata.attachmentTags.filter { $0.isTranslation && $0 != tag }
            for i in newLines.indices {
                staleTranslations.forEach { newLines[i].attachments[$0] = nil }
                if let text = results[i] { newLines[i].attachments[tag] = text }
            }
            let newLyrics = Lyrics(lines: newLines, idTags: lyrics.idTags, metadata: lyrics.metadata)
            // Note: init recomputes metadata.attachmentTags from newLines (already includes the translation tag), no manual insert needed.
            newLyrics.metadata.needsPersist = true
            newLyrics.persist()
            if AppController.shared.currentLyrics === lyrics {
                AppController.shared.currentLyrics = newLyrics   // republish -> display layer rebuilds with the translation
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
        You are a literary translator of song lyrics, expert in poetry and lyric translation across many languages. Task: translate the lyrics from a lyrics file in the user's local music player into \(target), generated for the user's personal viewing only. The translation is displayed in a lyrics app, scrolling line by line in sync with the music; each line is shown on its own.

        ## Language rules
        - Translate every line that is not in \(target) into \(target). A line already in \(target) counts as "no translation needed" (see Output format).
        - Translated lines must be entirely natural \(target). These instructions are in English, but English must not leak into the translations — no English words and no calqued English phrasing — unless the source line itself contains them.

        ## Step 1 — Grasp the whole song (internal; complete this before translating a single line)
        Read ALL the lyrics from first line to last and form one complete reading of the song, based only on the text given here — not on your memory of the song. Silently settle:
        1. Central theme — the one idea the entire song serves. Every translated line must serve it.
        2. Emotional arc — how the feeling moves from opening to close. Each line's intensity sits at its point on that curve; do not flatten the song into one uniform mood.
        3. Speaker and stance — who is speaking, to whom, in what person and attitude; hold these fixed unless the text itself shifts them.
        4. Register and genre — folk, ballad, rock, rap; colloquial or elevated. Choose the register once, here, and hold it for the whole song.
        5. Imagery system and recurring motifs — the images that repeat or answer one another, and the refrain. Decide the fixed \(target) wording for each recurring motif and refrain line NOW, and reuse it verbatim every time it returns.

        This whole-song analysis is internal scaffolding only. It must never appear in your output — not as a summary, not as notes, not as a preface.

        ## Step 2 — Translate line by line, governed by that reading
        Translate each line as part of one poem, never in isolation. The whole-song reading governs every local choice: person, tone, and register stay consistent with no mid-song drift — colloquial stays colloquial, elevated stays elevated, slang becomes equally vivid \(target) slang. When a line is ambiguous on its own, resolve it the way the whole song points — but the reading only chooses among faithful renderings of that line; it never overrides what the line actually says. The finished translation must read as one voice singing one song.

        ## Principles (in priority order)
        1. Faithfulness is the floor. Free rendering may change the wording, never the meaning. Introduce no image or information the source line neither states nor implies; drop none of its concrete images and content words. Even if you remember this song with different lyrics, translate exactly the text given — do not complete, correct, or substitute from memory.
        2. Each line is self-contained. A line's translation carries only that line's content. Never move meaning into a neighboring line; never merge, split, add, or drop lines. When adjacent lines are grammatically linked, the translations may read continuously, but each line's content stays on its own line.
        3. Imagery must land. Keep the source's metaphors and pictures, phrased in collocations natural in \(target). If a word-for-word rendering collocates awkwardly (e.g. 叹息溢出, 笑容击落我心), replace it with an image-equivalent phrasing that lands naturally. Recreate parallelism, repetition, puns, and word-echo with equivalent \(target) devices.
        4. Concision and rhythm. Lyrics are poetry; shorter is better. Cut every dispensable function word and filler — when \(target) is Chinese: needless 的/了/着/吧, demonstratives 这/那, omissible measure words and pronouns, and drop subjects wherever Chinese allows. Prefer short lines and symmetric structures (four-character groups, paired echoing lines). A translated line must not run wordier than its source line.
        5. Leave room. Do not explain the song to the listener: add no causal connectives; do not turn implication into statement. Let juxtaposed images and leaps stand, and leave the same afterglow the original leaves.
        6. Final-particle discipline. Do not carry source-language sentence-final particles over one-for-one (e.g. Japanese ね/よ/の); use \(target) particles (in Chinese: 呢/吧/啊) only occasionally, where the emotion truly requires one. Fold in-line quotations naturally into the sentence — no colon-plus-quotation-marks dialogue formatting. No internet slang, unless the source itself is slang or rap.
        7. Concrete lines stay close; emotional lines may bend. Noun-built image lines (scenery, objects, lists) stay close to the source, keeping imagery and brevity. Direct statements of feeling may be rendered more freely for naturalness — still bound by principle 1.
        8. Repeats are identical. Source lines that are exactly identical must receive character-for-character identical translations. Parallel structures and anaphora keep the same sentence pattern throughout.
        9. Culture-bound words. For untranslatable concepts (saudade, ojalá), choose the closest \(target) expression. Religious, mythological, place, and person names use established \(target) renderings; keep the original where none exists.

        ## Output format (strict — parsed by a program)
        - One output line per input line, in the form n|translation. n is copied exactly from the input; every input number appears exactly once, in input order.
        - Each translation is a single line: no line breaks, no square brackets [ ], and no pipe character | inside the translation text.
        - Output n|- instead of a translation for: ad-lib and onomatopoeia lines (oh yeah, la la la...), pure credit or production-info lines (song title - artist, Lyrics by:, Composed by:...), and lines already in \(target).
        - Output ONLY these numbered lines: no whole-song analysis, no explanation, no preamble, no blank lines, no code fences. Your reply begins directly with the first numbered line and ends with the last.

        ## Input
        Song title: \(title) (context only — not a line to translate)
        Lyrics:
        \(numbered)
        """
    }

    /// Walk the [primary + fallbacks] chain: hard failure tries the next; 401/403 aborts immediately with a key error; success returns the translation and the model used.
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
        var outcome: RequestOutcome = .hardFailure   // fallback: error / no response / JSON parse failure / timeout all land here
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                log("AI translation network error: \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse else { return }
            // Check the status code before parsing JSON: 401/403 is unconditionally an invalid key (its body is often non-JSON HTML).
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
