import Foundation
import ShouCore

func windowsCacheAccessNeverAuthorizesProfilesOrBroaderRoots() throws {
    let home=URL(fileURLWithPath: "/Users/cache-access-fixture")
    let access=try WindowsCacheAccess(homeDirectory: home)
    let locations=try KnownLocations.catalog(homeDirectory: home, platform: "windows")
    try expect(Set(locations.map(\.id)).count == locations.count && locations.count >= 23)
    for location in locations {
        try expect(access.permitsRoot(location.path))
        try expect(access.permitsRoot(location.path.uppercased()))
        try expect(!access.permitsTarget(location.path))
        try expect(!access.permitsRoot(location.path + "/arbitrary"))
    }
    let allowed=[
        "AppData/Local/Google/Chrome/User Data/Default/Cache",
        "AppData/Local/Google/Chrome/User Data/Profile 2/Code Cache/js/fixture.bin",
        "AppData/Local/Microsoft/Edge/User Data/Default/GPUCache",
        "AppData/Local/npm-cache/_cacache/content-v2/fixture.bin",
        "AppData/Local/pip/Cache/http-v2", "AppData/Local/pip/Cache/wheels",
        "AppData/Local/NuGet/v3-cache", "AppData/Roaming/Code/CachedData",
        ".gradle/caches", ".cargo/registry/cache",
        "AppData/Local/BraveSoftware/Brave-Browser/User Data/Profile 2/Cache/data_0",
        "AppData/Local/Vivaldi/User Data/Default/Code Cache/js",
        "AppData/Local/Mozilla/Firefox/Profiles/generated.default/cache2/entries",
        "AppData/Local/Mozilla/Firefox/Profiles/generated.default/startupCache",
        "AppData/Roaming/Slack/Cache", "AppData/Roaming/discord/Code Cache",
        "AppData/Roaming/Notion/GPUCache", "AppData/Roaming/Postman/Partitions/generated/Cache",
        "AppData/Roaming/Code - Insiders/CachedData/generated", "AppData/Roaming/Cursor/CachedData",
        "AppData/Local/Yarn/Cache/v6", "AppData/Local/uv/cache/wheels-v5",
        "AppData/Local/Chromium/User Data/Default/Cache/data_0",
        "AppData/Local/Chromium/User Data/Profile 2/Code Cache/js",
        "AppData/Roaming/obsidian/Cache/Cache_Data/data_0",
        "AppData/Roaming/obsidian/Code Cache/js", "AppData/Roaming/obsidian/GPUCache/data_0",
        "AppData/Roaming/GitHub Desktop/Cache", "AppData/Roaming/GitHub Desktop/Code Cache/js",
        "AppData/Roaming/GitHub Desktop/GPUCache/data_0",
        "AppData/Roaming/Insomnia/Cache", "AppData/Roaming/Insomnia/Code Cache/js", "AppData/Roaming/Insomnia/GPUCache/data_0"
    ]
    for relative in allowed {
        let path=home.path + "/" + relative
        guard access.permitsTarget(path) else { throw CheckFailure(description: "Declared cache denied: \(relative)") }
        try expect(access.permitsTarget(path.uppercased().replacingOccurrences(of: "/", with: "\\")))
    }
    let denied=[
        "AppData", "AppData/Local", "AppData/Roaming", "AppData/Local/Google/Chrome/User Data/Default",
        "AppData/Local/Google/Chrome/User Data/Default/Network", "AppData/Local/Google/Chrome/User Data/Default/Local Storage",
        "AppData/Local/Google/Chrome/User Data/Default/Sessions", "AppData/Local/Microsoft/Edge/User Data/Default/Extensions",
        "AppData/Local/NuGet/packages", "AppData/Roaming/Code/User/globalStorage", "AppData/Roaming/Code/Backups",
        ".cargo/registry/src", ".cargo/credentials.toml", ".gradle/gradle.properties",
        "AppData/Local/BraveSoftware/Brave-Browser/User Data/Profile 2/Extensions",
        "AppData/Local/Vivaldi/User Data/Default/Sessions",
        "AppData/Local/Mozilla/Firefox/Profiles/generated.default/bookmarkbackups",
        "AppData/Local/Mozilla/Firefox/Profiles/generated.default/storage",
        "AppData/Roaming/Mozilla/Firefox/Profiles/generated.default/cache2",
        "AppData/Roaming/Slack/IndexedDB", "AppData/Roaming/discord/Local Storage",
        "AppData/Roaming/Notion/Partitions/generated/IndexedDB",
        "AppData/Roaming/Postman/Partitions/generated/Storage",
        "AppData/Roaming/Code - Insiders/User/globalStorage", "AppData/Roaming/Cursor/Backups",
        "AppData/Local/Yarn/config", "AppData/Local/uv/python",
        "AppData/Local/Chromium/User Data/Default/IndexedDB", "AppData/Local/Chromium/User Data/Profile 2/Sessions",
        "AppData/Roaming/obsidian/IndexedDB", "AppData/Roaming/obsidian/Local Storage",
        "AppData/Roaming/obsidian/vault/Cache", "AppData/Roaming/obsidian/obsidian.json",
        "AppData/Roaming/GitHub Desktop/IndexedDB", "AppData/Roaming/GitHub Desktop/Local Storage",
        "AppData/Roaming/GitHub Desktop/repositories/project/Cache", "AppData/Roaming/GitHub Desktop/Cache-old",
        "AppData/Roaming/Insomnia/insomnia.Request.db", "AppData/Roaming/Insomnia/responses",
        "AppData/Roaming/Insomnia/plugins/plugin/Cache", "AppData/Roaming/Insomnia/git",
        "AppData/Roaming/Insomnia/Partitions/account/Cache",
        "AppData/Roaming/Slack/CacheStorage", "AppData/Roaming/discord/Cache-old",
        "AppData/Local/npm-cache/_cacache/../credentials", "AppData/Local/npm-cache/_cacache./payload",
        "AppData/Local/npm-cache/_cacache /payload", "AppData/Local/npm-cache/_cacache/file:stream",
        "AppData/Local/npm-cache//_cacache", "AppData/Local/npm-cache/_cacache/../../outside"
    ]
    for relative in denied {
        guard !access.permitsTarget(home.path + "/" + relative) else { throw CheckFailure(description: "Protected content authorized: \(relative)") }
    }
    try expect(!access.permitsRoot(home.path))
    try expect(!access.permitsTarget(home.path + "-other/AppData/Local/npm-cache/_cacache"))
    try expect(!access.permitsTarget("//server/share/AppData/Local/npm-cache/_cacache"))
    try expect(!access.permitsTarget("relative/AppData/Local/npm-cache/_cacache"))
}
