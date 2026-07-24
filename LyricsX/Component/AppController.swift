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
    /// Best floor-passing candidate whose artist doesn't match the query. Held off-screen while the
    /// search runs (a same-title wrong-artist hit must not flash, nor be persisted if the user skips);
    /// published only at stream end when nothing credible arrived.
    private var deferredCandidate: Lyrics?

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
        deferredCandidate = nil
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
        let cleanedTitle = cleanSearchTitle(title)
        let cleanedArtist = cleanSearchArtist(artist)
        // Escalating rounds: the conservative clean first; if it accepts nothing, retry with every bracket
        // group stripped (a bracketed translated alias yields zero provider hits and carries no noise token).
        var queryTitles = [cleanedTitle]
        let bare = bareSearchTitle(title)
        if bare != cleanedTitle { queryTitles.append(bare) }
        searchTask = Task { @MainActor in
            do {
                // Drain the whole provider stream, always keeping the best match. lyricsReceived shows the
                // first accepted result immediately and only replaces it with a higher-priority/higher-score
                // one, so display stays fast while a correct-but-slower match still wins. A fixed collection
                // window used to break early, discarding a right match that arrived late (e.g. from Musixmatch)
                // and letting a fast same-title wrong-artist result stick.
                var issued: [LyricsSearchRequest] = []
                for queryTitle in queryTitles {
                    let request = LyricsSearchRequest(
                        searchTerm: .info(title: queryTitle, artist: cleanedArtist),
                        duration: duration, limit: 5
                    )
                    issued.append(request)
                    searchRequest = request
                    for try await lyrics in lyricsManager.lyrics(for: request) {
                        lyricsReceived(lyrics: lyrics)
                    }
                    if currentLyrics != nil || Task.isCancelled { break }
                }
                flushDeferredCandidate(issuedRequests: issued)

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

    /// Stop the in-flight auto-search so its late-arriving candidates can't overwrite an explicit manual pick.
    func cancelSearch() {
        searchTask?.cancel()
        searchRequest = nil
        deferredCandidate = nil
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
        // Wrong-looking artist: keep it off-screen while better providers may still answer (it would flash
        // a wrong song, and persist as dirty cache if the user skips mid-search). Track the best of them.
        guard artistPlausible(lyrics, request: req, rawArtist: track.artist ?? "", trackDuration: track.duration) else {
            if deferredCandidate.map({ lyricsHasHigherPriority(lyrics, over: $0, trackAlbum: track.album) }) ?? true {
                deferredCandidate = lyrics
            }
            return
        }
        publish(lyrics, for: track)
    }

    private func publish(_ lyrics: Lyrics, for track: MusicTrack) {
        lyrics.associateWithTrack(track)
        lyrics.filtrate()
        lyrics.recognizeLanguage()
        lyrics.metadata.needsPersist = true
        currentLyrics = lyrics
    }

    /// All rounds ended with nothing credible on screen: fall back to the best wrong-artist candidate (same
    /// final outcome as before deferral existed, minus the misleading flash while the search was running).
    /// The candidate must come from one of this search session's own requests (cross-track race guard).
    private func flushDeferredCandidate(issuedRequests: [LyricsSearchRequest]) {
        guard let candidate = deferredCandidate else { return }
        deferredCandidate = nil
        guard currentLyrics == nil,
              candidate.metadata.request.map({ issuedRequests.contains($0) }) == true,
              let track = selectedPlayer.currentTrack else { return }
        publish(candidate, for: track)
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
        cancelSearch() // an imported file is an explicit pick — don't let a late auto candidate replace it
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
        let numbered = contents.enumerated().map { "\($0.offset + 1)|\($0.element)" }.joined(separator: "\n")
        // Prompt is Simplified-Chinese specific; targetCode still keys the translation attachment tag elsewhere.
        return """
        You are a literary translator of song lyrics, specializing in poetic, idiomatic Simplified Chinese. Work in the lineage of Chinese literary translation: prize 神似 over 形似 — likeness of spirit over likeness of surface — and aim for 化境, a rendering so natural it reads as though the song had first been conceived in Chinese. Reach 化境 only through rebuilt Chinese syntax, arranged pauses and punctuation, and the source's own imagery naturally rejoined — never through images or sentiments the source does not contain.

        Translate the supplied lyrics into natural Simplified Chinese for personal display in a synchronized lyrics player. Each input line has its own numbered display slot, so the physical line mapping is strict even when the Chinese sentence continues across adjacent lines.

        ## Priority

        Apply these rules in this order:

        1. Obey the output contract exactly.
        2. Preserve the source meaning, semantic relationships, and each source line's semantic anchor.
        3. Write natural, coherent Simplified Chinese while preserving genuine ambiguity.
        4. Recreate the song's imagery, voice, emotion, register, and rhetorical effect.
        5. Seek lyrical cadence without sacrificing any higher-priority rule.

        When two rules conflict, the higher-priority rule wins.

        ## Understand the whole song first

        First feel the whole song's style in both its content and its language — the linguistic style matters as much as the emotion. Settle the emotional tone — its temperature and how it shifts — and equally the song's verbal character: diction level, colloquial versus elevated voice, era and genre flavor, the texture of its sentences. Treat that felt style as the governing decision: let it drive the translation's rhythm, diction, and phrasing throughout, so every line serves the whole song's feeling and voice rather than being solved in isolation.

        Form a provisional understanding of:

        - speakers and addressees;
        - emotional movement and changes in intensity;
        - intentional shifts of voice or register against the baseline;
        - recurring images, refrains, and parallel structures;
        - grammatical units that continue across adjacent lines;
        - meaningful ambiguities, wordplay, and culture-bound expressions.

        Use the supplied title and lyrics as the authority. Do not complete, correct, or replace the text from memory, even if another version of the song is familiar. One narrow exception for surface corruption: a plainly truncated line or mechanical typo may be restored from an exact repetition of the same line elsewhere in this song. Never swap in a word from memory to "fix" a suspected transcription error when a different word would change or reverse the meaning (a negation, a pronoun like mi/tu, a singular/plural).

        Do not force the song into one thesis or invent an emotional progression the text does not support.

        ## Translation requirements

        - Translate every line that is not already entirely in natural Simplified Chinese: convert Traditional Chinese rather than treating it as already translated, and render a mixed-language line as one coherent Simplified Chinese line.
        - Preserve all material meaning — concrete images, relationships, negation, perspective, modality, and emotional implications.
        - Add nothing the source neither states nor implies — no new image, fact, cause, explanation, intensifier, or concretized abstraction. Match the source's emotional heat and physical explicitness exactly, in both directions: cooling or sanitizing is as unfaithful as intensifying; never inject physicality, desperation, or force the source does not voice.
        - Lexical items need no one-to-one match: change syntax, word class, or phrasing when idiomatic Chinese requires it, provided the meaning and poetic effect remain faithful.
        - Preserve striking metaphors, juxtapositions, and surreal images, and make their grammatical relationship land as natural Chinese — without explaining what they supposedly symbolize.
        - Preserve meaningful ambiguity. When the complete song clearly selects one reading, use it; otherwise prefer Chinese wording that retains the same openness (keep an ambiguous "estar en mí" as open between body and heart as the original). If no equally open Chinese expression exists, choose the least assumptive reading supported by the text.
        - Maintain a coherent overall voice while preserving intentional shifts of speaker, register, distance, attitude, or intensity. Render colloquial language as genuinely colloquial Chinese and elevated language as appropriately elevated Chinese; preserve humor, tenderness, restraint, slang, profanity, and erotic force.
        - Recreate parallelism, repetition, contrast, word echoes, and wordplay where a faithful Chinese equivalent is possible.
        - Do not add explanatory logic or causal relationships absent from the source. Minimal connectives, pronouns, subjects, particles, or punctuation are allowed when they express a relationship already present or make the Chinese grammatically natural.
        - Do not carry a source-language sentence-final particle or interjection over one-for-one (e.g. Japanese ね/よ/の/ねえ). Render it by register: a soft plea stays soft, a flat statement stays flat; use 呢/吧/啊 only where the emotion genuinely calls for one, and never map a gentle call to a brusque 喂.
        - Do not introduce 他 or 她 for a person whose gender the source leaves grammatically unmarked: use the person-noun, 你, 对方, or recast to drop the pronoun (su voz → 那嗓音, not 他的/她的). Gender a referent only when the source itself does (Spanish/Portuguese -o/-a endings, or explicit words).
        - Use established Simplified Chinese forms for recognized religious, mythological, geographical, historical, and personal names. Retain foreign wording only for deliberate code-switching, an established loanword, or a proper name without a suitable established Chinese form — never merely because the word appears in the source language.

        ## Natural Chinese style

        - Write fluent, contemporary Chinese appropriate to the song's actual genre and voice.
        - Avoid translationese and mechanical calques: prefer the natural Chinese idiom a lyricist would actually write over a multi-character literal rendering (not 无法相互理解 for わかりあえない).
        - Do not force rhyme, meter, symmetry, archaic or classical diction, idioms, or four-character structures where the source does not support them.
        - Do not automatically delete 的、了、着、这、那、pronouns, subjects, measure words, or sentence particles; use or omit them according to natural Chinese grammar, rhythm, and emphasis.
        - Set line length by need, not habit: a Chinese line may run longer than its source when naturalness, nuance, or beauty requires it — never compress merely for brevity — but elaborate only when the added words buy clarity, lyrical quality, or nuance that fits the whole song's established style. Never add words that carry nothing (a redundant 的人 or 内心, or a doubling the source does not have). When fidelity and brevity conflict, fidelity and naturalness take priority.

        ## Line mapping and cross-line syntax

        - Before translating a stanza, mentally restore its complete sentences free of the lyric line breaks — fix subject, object, pronoun reference, negation scope, modifier attachment, and prepositional relations — then distribute that reading back across the lines. Render a postposed subject or a verb split from its object by its true grammatical role, never as an unrelated fragment.
        - When adjacent source lines form one grammatical or poetic unit, translate them as one continuous Chinese sentence distributed across the corresponding output lines; an output line need not be a complete sentence by itself.
        - Keep each source line's principal image, action, or claim traceable to its corresponding output line. Function words, word order, grammatical completion, and minimal linking language may be arranged across immediately adjacent lines — never move a concrete image, action, or proposition onto a neighboring line to make it sound self-contained.
        - Use Chinese punctuation for clarity, rhythm, emotional pacing, quotation, interruption, and cross-line continuity: a line may end with a comma, semicolon, colon, dash, ellipsis, question mark, exclamation mark, or no terminal punctuation when its sentence continues. Do not mechanically place a full stop at the end of every line, and do not remove punctuation to make a line shorter.

        ## Repetition and refrains

        - Exactly repeated source lines normally receive identical Chinese wording; punctuation or a minimal grammatical adjustment may differ only when the surrounding cross-line syntax genuinely requires it.
        - Near-repetitions preserve their common structure and every meaningful difference: never normalize two source lines that differ, and never let consistency override a clearly different local meaning.
        - Review refrain wording after drafting the complete song rather than locking in the first occurrence.

        ## Quotations and expressive sounds

        - Render quotation and speech with natural Chinese syntax and punctuation; Chinese quotation marks, colons, dashes, and ellipses are allowed when they serve the source.
        - Translate or naturally recreate meaningful interjections, cries, calls, refrains, sound-symbolic expressions, and onomatopoeia when they contribute emotion, rhythm, imagery, or meaning.

        ## Lines that receive a hyphen

        Output n|- only when the source line:

        - is empty or contains only whitespace;
        - is already entirely in natural Simplified Chinese;
        - contains only song titles, credits, or production information;
        - consists solely of nonlexical vocalizing with no translatable semantic or emotional content.

        Never use - for a meaningful interjection, refrain, sound image, or mixed-language line; do not discard a line merely because it contains words such as ay, oh, hey, amen, boom, or knock.

        ## Output contract

        - Each input lyric line has the form n|source text. Output exactly one physical line for every input line, in the form n|translation.
        - Copy n exactly from the input. Every input number must appear exactly once, in the original order, so the output contains exactly as many physical lines as the numbered input.
        - The translation field must contain no line break, no square bracket, and no pipe character.
        - Use full-width Chinese punctuation throughout (，。？！：；……——“”); do not leave half-width , . ? ! : ; inside the translation text.
        - Output only the numbered result lines — no analysis, notes, alternatives, explanations, headings, prefaces, blank lines, or code fences. Begin directly with the first numbered output line and end with the last.

        ## Silent final check

        Before answering, silently verify the complete output:

        1. The line count, numbers, and order exactly match the input; every line follows n|translation or n|-; no translation field contains a pipe character, square bracket, or internal line break; nothing appears outside the numbered lines.
        2. Every use of - belongs to one of the permitted categories.
        3. Each source line's principal image, action, or claim sits on its own numbered output line — adjacent lines may share grammar, never swap content.
        4. Reverse-translate each finished line in your head: its subject, object, negation, and direction of action must match the source — a line that flips who does what to whom, or turns a negative positive, is wrong even if it reads beautifully. This check verifies meaning only — never wording; when the meaning is identical, always prefer the idiomatic Chinese rendering over a word-for-word one ("te vas sin mirar" → 头也不回地离开, not 转身不看便离去).

        ## Input

        Song title: \(title)

        The title is context only and is not an output line.

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
