//
//  MusixmatchToken.swift
//  LyricsX — 自动获取 Musixmatch web-desktop usertoken
//
//  Musixmatch(全球最大歌词库, 也是 Spotify 背后的源)需要一个 usertoken 才可用。
//  共享 trial token 会限流失效(401),用户手配很反人类。这里在启动/组装 provider 时
//  自动从公开 token.get 端点拉一个并缓存,注入 LyricsKit 的 AuthenticationManagerStore。
//

import Foundation

enum MusixmatchToken {
    private static let endpoint = URL(string: "https://apic-desktop.musixmatch.com/ws/1.1/token.get?app_id=web-desktop-app-v1.0&format=json")!

    /// 拉一个 usertoken;失败 / 占位串 / captcha 时返回 nil(调用方保留旧缓存)。
    static func fetch() async -> String? {
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.setValue("x-mxm-token-guid=", forHTTPHeaderField: "Cookie")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let header = message["header"] as? [String: Any],
              (header["status_code"] as? Int) == 200,
              let body = message["body"] as? [String: Any],
              let token = body["user_token"] as? String,
              !token.isEmpty, !token.hasPrefix("Upgrade")
        else {
            return nil
        }
        return token
    }
}
