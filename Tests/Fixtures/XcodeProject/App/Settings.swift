import Foundation

struct Settings {
    var verbose = false
    var unusedSetting = 0 // expect: unused

    static func load() -> Settings {
        var settings = Settings()
        settings.verbose = ProcessInfo.processInfo.arguments.contains("-v")
        return settings
    }

    func onlyUsedByTests() -> Bool { verbose }
}
