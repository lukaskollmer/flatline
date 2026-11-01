import ArgumentParser

@main
struct Flatline: ParsableCommand {
    static let version = "0.1.0"

    static let configuration = CommandConfiguration(
        commandName: "flatline",
        abstract: "Find unused code in Swift packages and Xcode projects.",
        version: version,
        subcommands: [Scan.self],
        defaultSubcommand: Scan.self
    )
}
