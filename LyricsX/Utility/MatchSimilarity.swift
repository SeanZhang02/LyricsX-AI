//
//  MatchSimilarity.swift
//  LyricsX — 搜索质量:查询清洗 / 折叠相似度 / app 侧择优分 / 匹配门
//
//  说明:LyricsKit 1.8.3 的 quality 公式 `1 - pow((1.05-a)(1.05-t)(1.05-d), 1/3)`
//  在 title/artist 恰好精确匹配(factor 1.5/1.3 > 1)时括号内为负 → pow 得 NaN,
//  使 `new.quality > existing.quality` 恒 false(错歌粘住)。这里用 app 侧加权分绕开。
//  相似度实现对照 1.8.3 `Lyrics+Quality.swift` 的 similarity(s1:s2:),额外做
//  大小写/变音符号/全半角折叠,使 "Ojalá"~"Ojala" 等价、跨字符集(日/西)恒 ≈0。
//

import Foundation
import LyricsXFoundation

// MARK: - 折叠相似度

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

/// 与 LyricsKit 1.8.3 similarity(s1:s2:) 等价(min-length 归一, 天然含子串容忍),先折叠。
/// "Despacito (feat. …)" vs "Despacito" ≈ 1.0;日语标题 vs 西语查询 ≈ 0。
func matchSimilarity(_ s1: String, _ s2: String) -> Double {
    let a = foldedChars(s1), b = foldedChars(s2)
    let len = min(a.count, b.count)
    guard len > 0 else { return 0 }
    let diff = min(editDistance(a, b, insertionCost: 0), editDistance(a, b, deletionCost: 0))
    return Double(len - diff) / Double(len)
}

// MARK: - 查询清洗(白名单去版本/feat 噪声, 提升召回)

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

/// 删除内容命中噪声词的括号组(() [] （） 【】), 循环到稳定(处理连续/删后新露出的组)。
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

/// 去掉噪声括号组与尾部 " - Xxx" 版本后缀;结果为空回退原串。
/// 只删含噪声词的括号,保留 "(I Can't Get No) Satisfaction" 这类歌名自带括号。
func cleanSearchTitle(_ title: String) -> String {
    var s = removeNoiseBrackets(title)
    if let dash = s.range(of: " - ", options: .backwards), containsVersionNoise(s[dash.upperBound...]) {
        s = String(s[..<dash.lowerBound])
    }
    s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    return s.isEmpty ? title : s
}

/// 先去掉 "(feat. X)" 噪声括号, 再只在 feat 标记与 CJK 顿号处截断艺人。
/// ⚠️ 绝不按 &/,// 截(会切碎 Simon & Garfunkel、AC/DC)。
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

// MARK: - app 侧择优分(NaN-free, 替换 1.8.3 quality)

private func durationScore(_ lyrics: Lyrics) -> Double {
    guard let len = lyrics.length, let searchDuration = lyrics.metadata.request?.duration, searchDuration > 0 else {
        return 0.6
    }
    let dt = abs(searchDuration - len)
    guard dt < 10 else { return 0.5 }
    return 1 - pow(dt / 10, 2) * 0.5
}

private func albumBonus(_ lyrics: Lyrics, trackAlbum: String?) -> Double {
    guard let trackAlbum, !trackAlbum.isEmpty,
          let candAlbum = lyrics.idTags[.album], !candAlbum.isEmpty else {
        return 0 // 任一方专辑未知 → 不奖不罚(QQ/Kugou 不设 album)
    }
    let a = foldedString(candAlbum), b = foldedString(trackAlbum)
    if a.contains(b) || b.contains(a) || matchSimilarity(candAlbum, trackAlbum) >= 0.8 {
        return 0.08
    }
    return 0
}

/// 加权相似度(artist .45 / title .40 / duration .15 + 翻译/时轴 bonus 各 .05)+ 专辑 bonus。
/// 不用 LyricsKit 1.8.3 的 quality(有 NaN bug),从根上消除"精确匹配却换不掉现任"。
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

// MARK: - 匹配门 C(+ D 兜底 + 时长豁免)

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

/// 拒绝与查询"完全不相干"的候选(治西语→日语粗错)。true=通过。独立于 strictSearchEnabled。
/// C:双 tag 都在时 titleSim<0.3 且 artistSim<0.3 才拒(sim 取原始 track 值与清洗 query 值的较大者);
/// 单侧 tag 缺 → 该侧不判(fail-open);双缺 → D 兜底(查询纯拉丁 && 歌词正文 CJK 则拒)。
/// 时长豁免:候选时长与曲目时长差 <3s 一律放行(救罗马字 tag/CJK 歌词的正确歌)。
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
    // 双 tag 都缺(1.8.3 现网不可达, 留作未来 provider 保险)
    if candTitle == nil, candArtist == nil {
        if !hasCJK(rawTitle + rawArtist + queryTitle + queryArtist), lyricsBodyIsMostlyCJK(lyrics) {
            return false
        }
    }
    return true // 单侧缺失或 D 不触发 → 放行
}
