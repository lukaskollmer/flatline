import CIndexStore
import Foundation

/// Metadata of one compilation unit (one compiled source file or module).
public struct IndexUnit: Sendable {
    public struct Dependency: Sendable {
        public enum Kind: UInt32, Sendable {
            case unit = 1
            case record = 2
            case file = 3
        }

        public let kind: Kind
        /// The record or unit name, for record and unit dependencies.
        public let name: String
        public let filePath: String
        public let moduleName: String
        public let isSystem: Bool
    }

    public let name: String
    public let mainFile: String?
    public let moduleName: String
    public let providerIdentifier: String
    public let target: String
    public let outputFile: String
    public let workingDirectory: String
    public let isSystem: Bool
    public let isModuleUnit: Bool
    public let modificationTime: Date
    public let dependencies: [Dependency]
}

/// A read-only view of an index store directory.
public final class IndexStore: @unchecked Sendable {
    public let path: String
    public let library: IndexStoreLibrary
    private let store: indexstore_t

    public init(path: String, library: IndexStoreLibrary) throws {
        self.path = path
        self.library = library
        store = try library.check { library.api.store_create(path, $0) }
    }

    deinit {
        library.api.store_dispose(store)
    }

    public func unitNames() -> [String] {
        var names: [String] = []
        withContext({ (name: indexstore_string_ref_t) -> Bool in
            names.append(name.string)
            return true
        }) { context in
            _ = library.api.store_units_apply_f(store, 0, context) { context, name in
                context.callback(as: indexstore_string_ref_t.self)(name)
            }
        }
        return names
    }

    public func unit(named name: String) throws -> IndexUnit {
        let api = library.api
        let reader = try library.check { api.unit_reader_create(store, name, $0) }
        defer { api.unit_reader_dispose(reader) }

        var dependencies: [IndexUnit.Dependency] = []
        withContext({ (dependency: indexstore_unit_dependency_t?) -> Bool in
            guard let dependency,
                  let kind = IndexUnit.Dependency.Kind(rawValue: api.unit_dependency_get_kind(dependency))
            else { return true }
            dependencies.append(IndexUnit.Dependency(
                kind: kind,
                name: api.unit_dependency_get_name(dependency).string,
                filePath: api.unit_dependency_get_filepath(dependency).string,
                moduleName: api.unit_dependency_get_modulename(dependency).string,
                isSystem: api.unit_dependency_is_system(dependency)
            ))
            return true
        }) { context in
            _ = api.unit_reader_dependencies_apply_f(reader, context) { context, dependency in
                context.callback(as: indexstore_unit_dependency_t?.self)(dependency)
            }
        }

        var seconds: Int64 = 0
        var nanoseconds: Int64 = 0
        api.unit_reader_get_modification_time(reader, &seconds, &nanoseconds)

        return IndexUnit(
            name: name,
            mainFile: api.unit_reader_has_main_file(reader) ? api.unit_reader_get_main_file(reader).string : nil,
            moduleName: api.unit_reader_get_module_name(reader).string,
            providerIdentifier: api.unit_reader_get_provider_identifier(reader).string,
            target: api.unit_reader_get_target(reader).string,
            outputFile: api.unit_reader_get_output_file(reader).string,
            workingDirectory: api.unit_reader_get_working_dir(reader).string,
            isSystem: api.unit_reader_is_system_unit(reader),
            isModuleUnit: api.unit_reader_is_module_unit(reader),
            modificationTime: Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanoseconds) / 1e9),
            dependencies: dependencies
        )
    }

    /// Reads every occurrence in a record.
    public func occurrences(inRecord name: String) throws -> [SymbolOccurrence] {
        let api = library.api
        let reader = try library.check { api.record_reader_create(store, name, $0) }
        defer { api.record_reader_dispose(reader) }

        // Symbols are owned by the reader, so pointers are stable while it lives.
        var symbols: [UnsafeMutableRawPointer: Symbol] = [:]
        func symbol(_ pointer: indexstore_symbol_t) -> Symbol {
            if let cached = symbols[pointer] { return cached }
            let symbol = Symbol(
                usr: api.symbol_get_usr(pointer).string,
                name: api.symbol_get_name(pointer).string,
                kind: SymbolKind(rawValue: api.symbol_get_kind(pointer)) ?? .unknown,
                subkind: SymbolSubkind(rawValue: api.symbol_get_subkind(pointer)) ?? .none,
                properties: SymbolProperties(rawValue: api.symbol_get_properties(pointer)),
                language: SymbolLanguage(rawValue: api.symbol_get_language(pointer)) ?? .unknown
            )
            symbols[pointer] = symbol
            return symbol
        }

        var occurrences: [SymbolOccurrence] = []
        withContext({ (occurrence: indexstore_occurrence_t?) -> Bool in
            guard let occurrence, let occurrenceSymbol = api.occurrence_get_symbol(occurrence) else { return true }

            var relations: [SymbolRelation] = []
            withContext({ (relation: indexstore_symbol_relation_t?) -> Bool in
                if let relation, let relatedSymbol = api.symbol_relation_get_symbol(relation) {
                    relations.append(SymbolRelation(
                        roles: SymbolRoles(rawValue: api.symbol_relation_get_roles(relation)),
                        symbol: symbol(relatedSymbol)
                    ))
                }
                return true
            }) { context in
                _ = api.occurrence_relations_apply_f(occurrence, context) { context, relation in
                    context.callback(as: indexstore_symbol_relation_t?.self)(relation)
                }
            }

            var line: UInt32 = 0
            var column: UInt32 = 0
            api.occurrence_get_line_col(occurrence, &line, &column)
            occurrences.append(SymbolOccurrence(
                symbol: symbol(occurrenceSymbol),
                roles: SymbolRoles(rawValue: api.occurrence_get_roles(occurrence)),
                line: Int(line),
                column: Int(column),
                relations: relations
            ))
            return true
        }) { context in
            _ = api.record_reader_occurrences_apply_f(reader, context) { context, occurrence in
                context.callback(as: indexstore_occurrence_t?.self)(occurrence)
            }
        }
        return occurrences
    }
}

// MARK: - Callback plumbing

/// Passes a non-escaping Swift closure through a C `void *context` parameter.
private func withContext<Argument>(
    _ callback: (Argument) -> Bool,
    _ body: (UnsafeMutableRawPointer) -> Void
) {
    withoutActuallyEscaping(callback) { callback in
        var box = CallbackBox(callback: callback)
        withUnsafeMutablePointer(to: &box) { body(UnsafeMutableRawPointer($0)) }
    }
}

private struct CallbackBox<Argument> {
    let callback: (Argument) -> Bool
}

private extension Optional where Wrapped == UnsafeMutableRawPointer {
    func callback<Argument>(as _: Argument.Type) -> (Argument) -> Bool {
        self!.assumingMemoryBound(to: CallbackBox<Argument>.self).pointee.callback
    }
}
