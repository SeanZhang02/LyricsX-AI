//
//  MatchSimilarity.swift
//  LyricsX — search quality: query cleaning / folded similarity / app-side ranking score / match floor
//
//  LyricsKit 1.8.3's quality formula `1 - pow((1.05-a)(1.05-t)(1.05-d), 1/3)` yields NaN when title
//  or artist matches exactly (factor 1.5/1.3 > 1 makes the base negative), which makes
//  `new.quality > existing.quality` always false (a wrong pick sticks). We rank with an app-side
//  weighted score instead. Similarity mirrors 1.8.3 `Lyrics+Quality.swift` similarity(s1:s2:), plus
//  case/diacritic/width folding so "Ojalá" ~ "Ojala" and cross-script (JA vs ES) stays ~0.
//

import Foundation
import LyricsXFoundation

// MARK: - Folded similarity

private func foldedChars(_ s: String) -> [Character] {
    Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil))
}

private func foldedString(_ s: String) -> String {
    s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
}

private func editDistance(_ lhs: [Character], _ rhs: [Character], insertionCost: Int = 1, deletionCost: Int = 1) -> Int {
    var d = Array(0 ... rhs.count)
    var t = 0
    for c1 in lhs {
        t = d[0]
        d[0] += 1
        for (i, c2) in rhs.enumerated() {
            let t2 = d[i + 1]
            if c1 == c2 {
                d[i + 1] = t
            } else {
                d[i + 1] = Swift.min(t + 1, d[i] + insertionCost, t2 + deletionCost)
            }
            t = t2
        }
    }
    return d.last!
}

/// Mirrors LyricsKit 1.8.3 similarity(s1:s2:) (min-length normalized, tolerates containment), folded first.
/// "Despacito (feat. …)" vs "Despacito" ≈ 1.0; a Japanese title vs a Spanish query ≈ 0.
func matchSimilarity(_ s1: String, _ s2: String) -> Double {
    let a = foldedChars(s1), b = foldedChars(s2)
    let len = min(a.count, b.count)
    guard len > 0 else { return 0 }
    let diff = min(editDistance(a, b, insertionCost: 0), editDistance(a, b, deletionCost: 0))
    return Double(len - diff) / Double(len)
}

// MARK: - Query cleaning (whitelist-drop version/feat noise to improve recall)

private let versionNoiseTokens: Set<String> = [
    "feat", "ft", "featuring", "with", "prod", "remaster", "remastered", "deluxe",
    "anniversary", "edition", "version", "ver", "radio", "single", "album", "bonus",
    "live", "acoustic", "unplugged", "demo", "mono", "stereo", "explicit", "clean",
    "remix", "cover", "instrumental", "karaoke", "vocal", "from",
]
private let cjkNoiseSubstrings = ["伴奏", "现场", "翻自", "纯音乐", "无损", "翻唱"]

private func containsVersionNoise<S: StringProtocol>(_ inner: S) -> Bool {
    let lower = inner.lowercased()
    if cjkNoiseSubstrings.contains(where: { lower.contains($0) }) { return true }
    let tokens = lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    return tokens.contains { versionNoiseTokens.contains($0) }
}

/// Drop bracket groups whose content contains a noise token, looping until stable (handles adjacent/revealed groups).
private func removeNoiseBrackets(_ input: String) -> String {
    guard let re = try? NSRegularExpression(pattern: "[\\(\\[（【][^\\(\\[（【\\)\\]）】]*[\\)\\]）】]") else { return input }
    var s = input
    for _ in 0 ..< 3 {
        let ns = s as NSString
        var removals: [NSRange] = []
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let inner = ns.substring(with: m.range).dropFirst().dropLast()
            if containsVersionNoise(inner) { removals.append(m.range) }
        }
        if removals.isEmpty { break }
        for r in removals.reversed() { s = (s as NSString).replacingCharacters(in: r, with: "") }
    }
    return s
}

/// Only drops brackets containing a noise token, so a title's own parenthetical (e.g. "(I Can't Get No) Satisfaction") is kept.
func cleanSearchTitle(_ title: String) -> String {
    var s = removeNoiseBrackets(title)
    if let dash = s.range(of: " - ", options: .backwards), containsVersionNoise(s[dash.upperBound...]) {
        s = String(s[..<dash.lowerBound])
    }
    s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    return s.isEmpty ? title : s
}

/// Truncate the artist only at a feat marker or a CJK enumeration comma — never at &/,/ (would split band names like Simon & Garfunkel, AC/DC).
func cleanSearchArtist(_ artist: String) -> String {
    var s = removeNoiseBrackets(artist)
    var cut = s.endIndex
    for marker in [" feat.", " feat ", " ft.", " ft ", " featuring "] {
        if let r = s.range(of: marker, options: .caseInsensitive), r.lowerBound < cut {
            cut = r.lowerBound
        }
    }
    s = String(s[..<cut])
    if let r = s.range(of: "、") { s = String(s[..<r.lowerBound]) }
    let out = s.trimmingCharacters(in: .whitespaces)
    return out.isEmpty ? artist : out
}

// MARK: - App-side ranking score (NaN-free replacement for 1.8.3 quality)

private func durationScore(_ lyrics: Lyrics) -> Double {
    guard let len = lyrics.length, let searchDuration = lyrics.metadata.request?.duration, searchDuration > 0 else {
        return 0.6
    }
    let dt = abs(searchDuration - len)
    guard dt < 10 else { return 0.5 }
    return 1 - pow(dt / 10, 2) * 0.5
}

private func albumBonus(_ lyrics: Lyrics, trackAlbum: String?) -> Double {
    // Either side's album unknown → neither reward nor penalty (QQ/Kugou don't set album).
    guard let trackAlbum, !trackAlbum.isEmpty,
          let candAlbum = lyrics.idTags[.album], !candAlbum.isEmpty else {
        return 0
    }
    let a = foldedString(candAlbum), b = foldedString(trackAlbum)
    if a.contains(b) || b.contains(a) || matchSimilarity(candAlbum, trackAlbum) >= 0.8 {
        return 0.08
    }
    return 0
}

/// Weighted similarity (artist .45 / title .40 / duration .15 + translation/timetag bonus .05 each) + album bonus.
/// Avoids 1.8.3 quality's NaN bug so an exact match can actually replace the incumbent.
func appMatchScore(_ lyrics: Lyrics, trackAlbum: String?) -> Double {
    let titleSim: Double
    let artistSim: Double
    switch lyrics.metadata.request?.searchTerm {
    case let .info(searchTitle, searchArtist)?:
        titleSim = lyrics.idTags[.title].flatMap { $0.isEmpty ? nil : $0 }.map { matchSimilarity($0, searchTitle) } ?? 0.6
        artistSim = lyrics.idTags[.artist].flatMap { $0.isEmpty ? nil : $0 }.map { matchSimilarity($0, searchArtist) } ?? 0.6
    default:
        let q = lyrics.quality
        return q.isNaN ? 0 : q
    }
    var score = artistSim * 0.45 + titleSim * 0.40 + durationScore(lyrics) * 0.15
    if lyrics.metadata.hasTranslation { score += 0.05 }
    if lyrics.metadata.attachmentTags.contains(.timetag) { score += 0.05 }
    score += albumBonus(lyrics, trackAlbum: trackAlbum)
    return score
}

// MARK: - Match floor C (+ D backstop + duration exemption)

private func hasCJK(_ s: String) -> Bool {
    s.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
}

private func lyricsBodyIsMostlyCJK(_ lyrics: Lyrics) -> Bool {
    let text = lyrics.lines.prefix(12).map(\.content).joined()
    var cjk = 0, latin = 0
    for u in text.unicodeScalars {
        if (0x3040...0x9FFF).contains(u.value) || (0xAC00...0xD7AF).contains(u.value) { cjk += 1 }
        else if (0x41...0x5A).contains(u.value) || (0x61...0x7A).contains(u.value) { latin += 1 }
    }
    return cjk >= 5 && cjk > latin
}

/// Reject candidates completely unrelated to the query (fixes e.g. a Spanish song matching a Japanese one). true = pass.
/// Independent of strictSearchEnabled. C: with both tags present, reject only when titleSim < 0.3 AND artistSim < 0.3
/// (sim takes the max of raw track value and cleaned query value); a missing tag skips that side (fail-open); both
/// missing → D backstop (query is Latin-only AND lyrics body is CJK → reject). Duration exemption: candidate length
/// within 3s of the track passes unconditionally (saves the correct song when its tags are romanized but lyrics are CJK).
func passesMatchFloor(_ lyrics: Lyrics, request: LyricsSearchRequest, rawTitle: String, rawArtist: String, trackDuration: TimeInterval?) -> Bool {
    if let len = lyrics.length, let dur = trackDuration, dur > 0, abs(len - dur) < 3 {
        return true
    }
    let queryTitle: String, queryArtist: String
    switch request.searchTerm {
    case let .info(t, a): queryTitle = t; queryArtist = a
    case .keyword: return true
    }
    let candTitle = lyrics.idTags[.title].flatMap { $0.isEmpty ? nil : $0 }
    let candArtist = lyrics.idTags[.artist].flatMap { $0.isEmpty ? nil : $0 }

    if let ct = candTitle, let ca = candArtist {
        let titleSim = max(matchSimilarity(ct, rawTitle), matchSimilarity(ct, queryTitle))
        let artistSim = max(matchSimilarity(ca, rawArtist), matchSimilarity(ca, queryArtist))
        return !(titleSim < 0.3 && artistSim < 0.3)
    }
    // Both tags missing (unreachable on 1.8.3 providers, kept as a backstop for future providers)
    if candTitle == nil, candArtist == nil {
        if !hasCJK(rawTitle + rawArtist + queryTitle + queryArtist), lyricsBodyIsMostlyCJK(lyrics) {
            return false
        }
    }
    return true
}

/// Whether the candidate's artist is close enough to the query to be shown while the search is still running.
/// A same-title different-artist hit (e.g. a popular cover with a bundled translation) passes the match floor
/// but would flash a wrong song before a slower provider returns the right one — hold it back instead.
/// Fail-open like the floor: missing artist tag or keyword search can't be judged; a duration within 3s
/// passes unconditionally (saves the correct song whose artist tag is romanized/translated).
func artistPlausible(_ lyrics: Lyrics, request: LyricsSearchRequest, rawArtist: String, trackDuration: TimeInterval?) -> Bool {
    if let len = lyrics.length, let dur = trackDuration, dur > 0, abs(len - dur) < 3 {
        return true
    }
    guard case let .info(_, queryArtist) = request.searchTerm,
          let candArtist = lyrics.idTags[.artist].flatMap({ $0.isEmpty ? nil : $0 }),
          !(rawArtist.isEmpty && queryArtist.isEmpty) else {
        // No artist on either side to judge by — fail open, or artist-less tracks would lose fast display.
        return true
    }
    return max(matchSimilarity(candArtist, rawArtist), matchSimilarity(candArtist, queryArtist)) >= 0.3
}
