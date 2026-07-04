// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

import Foundation
import os.log

/// Best-effort "is there a newer release?" check against the GitHub releases
/// API, run once at launch. Every failure path (no network, rate limit, bad
/// JSON, timeout) resolves to "no update" quietly — a background menu bar tool
/// must never interrupt the user with update-check errors. The only network
/// call pype makes; it sends no data beyond a standard request.
enum UpdateChecker {
    private static let logger = Logger(subsystem: "pype", category: "update-check")

    /// - Returns: the newer version string (e.g. "1.0.2") if the latest GitHub
    ///   release is strictly higher than the running version; otherwise nil.
    static func newerVersion() async -> String? {
        guard let url = URL(string: AppInfo.latestReleaseApiUrl) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        // GitHub's API requires a User-Agent; Accept pins the API version.
        request.setValue("pype-update-check", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                return nil
            }
            let normalizedTag = normalize(tag)
            guard let remote = parse(normalizedTag), let local = parse(normalize(AppInfo.version)) else {
                // A non-numeric tag (e.g. a "v1.1.0-beta" pre-release someone
                // marked as latest) is treated as "no update" - matching the
                // Windows side, which rejects unparseable versions rather than
                // guessing and showing a ragged string.
                return nil
            }
            return isNewer(remote, than: local) ? normalizedTag : nil
        } catch {
            logger.notice("Update check skipped: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // Tags look like "v1.0.2"; strip a leading v and keep the numeric core.
    private static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    // Parses a dotted version into integer components. Returns nil if ANY
    // component isn't a plain integer, so pre-release/build-metadata tags
    // ("1.1.0-beta", "1.0.0+build") are rejected rather than coerced.
    private static func parse(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var out: [Int] = []
        for part in parts {
            guard let n = Int(part) else { return nil }
            out.append(n)
        }
        return out
    }

    // Compares integer version components (1.0.10 > 1.0.9). Missing trailing
    // components count as 0, so [1,0] == [1,0,0].
    private static func isNewer(_ lhs: [Int], than rhs: [Int]) -> Bool {
        let count = max(lhs.count, rhs.count)
        for i in 0..<count {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
