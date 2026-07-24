//
//  MusixmatchToken.swift
//  LyricsX — auto-fetch a Musixmatch web-desktop usertoken
//
//  Musixmatch (the largest global lyrics source, also what Spotify serves) needs a usertoken.
//  Shared trial tokens get rate-limited (401) and asking users to configure one is user-hostile,
//  so we fetch one from the public token.get endpoint on launch and cache it, injecting it into
//  LyricsKit's AuthenticationManagerStore.
//

import Foundation

enum MusixmatchToken {
    private static let endpoint = URL(string: "https://apic-desktop.musixmatch.com/ws/1.1/token.get?app_id=web-desktop-app-v1.0&format=json")!

    /// Returns a usertoken; nil on failure / placeholder / captcha (caller keeps the previous cache).
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
