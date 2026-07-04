// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 pype contributors

using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;

namespace Pype;

/// <summary>
/// Best-effort "is there a newer release?" check against the GitHub releases
/// API, run once at launch. Every failure path (no network, rate limit, bad
/// JSON, timeout) returns "no update" quietly — a background clipboard tool
/// must never interrupt the user with update-check errors. The only network
/// call pype makes; it sends no data beyond a standard request.
/// </summary>
internal static class UpdateChecker
{
    private static readonly HttpClient Http = CreateClient();

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
        // GitHub's API requires a User-Agent; the Accept header pins the API version.
        client.DefaultRequestHeaders.UserAgent.ParseAdd("pype-update-check");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return client;
    }

    /// <summary>The running app's version as a display string, e.g. "1.0.2".</summary>
    public static string LocalVersionString => LocalVersion.ToString();

    private static Version LocalVersion
    {
        get
        {
            var v = typeof(UpdateChecker).Assembly.GetName().Version ?? new Version(0, 0, 0);
            return new Version(v.Major, v.Minor, Math.Max(v.Build, 0));
        }
    }

    /// <returns>
    /// The newer version's display string (e.g. "1.0.2") if the latest GitHub
    /// release is strictly higher than the running version; otherwise null
    /// (up to date, or any failure).
    /// </returns>
    public static async Task<string?> GetNewerVersionAsync()
    {
        try
        {
            using var response = await Http.GetAsync(AppInfo.LatestReleaseApiUrl);
            if (!response.IsSuccessStatusCode) return null;

            await using var stream = await response.Content.ReadAsStreamAsync();
            using var doc = await JsonDocument.ParseAsync(stream);
            if (!doc.RootElement.TryGetProperty("tag_name", out var tagElement)) return null;

            var remote = ParseVersion(tagElement.GetString());
            if (remote is null) return null;

            return remote > LocalVersion ? remote.ToString() : null;
        }
        catch
        {
            return null;
        }
    }

    // Tags look like "v1.0.2"; strip the leading v and normalize to 3 numeric
    // components so comparison against the assembly version is apples-to-apples.
    private static Version? ParseVersion(string? tag)
    {
        if (string.IsNullOrWhiteSpace(tag)) return null;
        string s = tag.Trim().TrimStart('v', 'V');
        return Version.TryParse(s, out var v)
            ? new Version(v.Major, v.Minor, Math.Max(v.Build, 0))
            : null;
    }
}
