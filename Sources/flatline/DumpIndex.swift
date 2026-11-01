import ArgumentParser
import FlatlineCore
import FlatlineProject
import Foundation
import IndexStore

/// Prints raw index occurrences, for debugging flatline's results.
struct DumpIndex: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump-index",
        abstract: "Print the index occurrences of matching source files.",
        shouldDisplay: false
    )

    @Option(help: "The index store to read.")
    var indexStorePath: String

    @Option(help: "Path to libIndexStore.")
    var indexStoreLibrary: String?

    @Argument(help: "Only dump units whose main file contains this text.")
    var file: String

    func run() throws {
        let library = try IndexStoreLibrary(path: Toolchain.indexStoreLibrary(explicit: indexStoreLibrary))
        let store = try IndexStore(path: indexStorePath, library: library)
        for name in store.unitNames() {
            let unit = try store.unit(named: name)
            guard !unit.isSystem, let mainFile = unit.mainFile, mainFile.contains(file) else { continue }
            print("unit \(name) module=\(unit.moduleName) file=\(mainFile) modified=\(unit.modificationTime)")
            for dependency in unit.dependencies where dependency.kind == .record {
                for occurrence in try store.occurrences(inRecord: dependency.name) {
                    let symbol = occurrence.symbol
                    let relations = occurrence.relations.map {
                        "\(describe($0.roles)) \($0.symbol.name) [\($0.symbol.usr)]"
                    }
                    print(
                        "  \(occurrence.line):\(occurrence.column) \(symbol.kind)/\(symbol.subkind) '\(symbol.name)' "
                            + "[\(symbol.usr)] \(describe(occurrence.roles))"
                            + (relations.isEmpty ? "" : " → " + relations.joined(separator: ", "))
                    )
                }
            }
        }
    }

    private func describe(_ roles: SymbolRoles) -> String {
        let names: [(SymbolRoles, String)] = [
            (.declaration, "decl"), (.definition, "def"), (.reference, "ref"), (.read, "read"),
            (.write, "write"), (.call, "call"), (.dynamic, "dynamic"), (.addressOf, "addressOf"),
            (.implicit, "implicit"), (.childOf, "childOf"), (.baseOf, "baseOf"), (.overrideOf, "overrideOf"),
            (.receivedBy, "receivedBy"), (.calledBy, "calledBy"), (.extendedBy, "extendedBy"),
            (.accessorOf, "accessorOf"), (.containedBy, "containedBy"), (.ibTypeOf, "ibTypeOf"),
            (.specializationOf, "specializationOf"),
        ]
        return names.filter { roles.contains($0.0) }.map(\.1).joined(separator: "|")
    }
}
