@testable import FlatlineSwift
import Testing

struct SyntaxCollectorTests {
    private func collect(_ source: String) -> FileSyntaxInfo {
        SyntaxCollector.collect(source: source, path: "/tmp/Test.swift")
    }

    private func declaration(_ name: String, in info: FileSyntaxInfo) throws -> DeclarationSyntaxInfo {
        try #require(info.scopes.first { $0.name == name }, "no declaration named \(name)")
    }

    @Test func keysDeclarationsByNamePosition() throws {
        let info = collect("""
        struct Foo {
            init(x: Int) {}
            subscript(i: Int) -> Int { i }
            static func + (lhs: Foo, rhs: Foo) -> Foo { lhs }
        }
        extension Swift.String {}
        """)
        #expect(info.declarations[Position(line: 1, column: 8)]?.name == "Foo")
        #expect(info.declarations[Position(line: 2, column: 5)]?.name == "init")
        #expect(info.declarations[Position(line: 3, column: 5)]?.name == "subscript")
        #expect(info.declarations[Position(line: 4, column: 17)]?.name == "+")
        // Extensions are found under both the last and the first component.
        #expect(info.declarations[Position(line: 6, column: 17)]?.name == "String")
        #expect(info.declarations[Position(line: 6, column: 11)]?.name == "String")
    }

    @Test func readsAttributesModifiersAndAccessibility() throws {
        let info = collect("""
        @objc(Named) public final class Foo {
            @IBAction private func tap(_ sender: Any) {}
            public private(set) var value = 0
            @available(*, unavailable) func gone() {}
        }
        """)
        let foo = try declaration("Foo", in: info)
        #expect(foo.attributes == ["objc"])
        #expect(foo.modifiers == ["public", "final"])
        #expect(foo.accessibility == .public)
        #expect(try declaration("tap", in: info).accessibility == .private)
        let value = try declaration("value", in: info)
        #expect(value.accessibility == .public)
        #expect(value.modifiers.contains("private(set)"))
        #expect(try declaration("gone", in: info).attributes.contains("available(unavailable)"))
    }

    @Test func parsesCommentCommands() throws {
        let info = collect("""
        // flatline:ignore
        func a() {}
        // periphery:ignore - reason
        func b() {}
        /* flatline:ignore:parameters x, y */
        func c(x: Int, y: Int, z: Int) {}
        /// Docs.
        func d() {}
        """)
        #expect(try declaration("a", in: info).isIgnored)
        #expect(try declaration("b", in: info).isIgnored)
        let c = try declaration("c", in: info)
        #expect(!c.isIgnored)
        #expect(c.ignoredParameters == ["x", "y"])
        #expect(try declaration("d", in: info).commands.isEmpty)
        #expect(!info.ignoresAll)
        #expect(collect("// flatline:ignore:all\nfunc e() {}").ignoresAll)
    }

    @Test func tracksParameterUsage() throws {
        let info = collect("""
        func f(a: Int, b: Int, _ c: Int?, d: Int, `default`: Int, _: Int) -> () -> Int {
            if let c { print(c) }
            print("\\(a)")
            return { [d] in d + `default` }
        }
        """)
        let parameters = try declaration("f", in: info).parameters
        #expect(parameters.map(\.name) == ["a", "b", "c", "d", "default"])
        #expect(parameters.filter { !$0.isUsed }.map(\.name) == ["b"])
    }

    @Test func detectsStubs() throws {
        let info = collect("""
        func a(x: Int) { fatalError() }
        func b(x: Int) {}
        func c(x: Int) { print(x); fatalError() }
        """)
        #expect(try declaration("a", in: info).isStub)
        #expect(try declaration("b", in: info).isStub)
        #expect(try !declaration("c", in: info).isStub)
    }

    @Test func classifiesVariables() throws {
        let info = collect("""
        struct S {
            var stored = 0
            var observed = 0 { didSet {} }
            var computed: Int { 1 }
            var accessors: Int { get { 1 } set {} }
            let (first, second): (Int, Int) = (1, 2)
        }
        """)
        #expect(try declaration("stored", in: info).isStored)
        let observed = try declaration("observed", in: info)
        #expect(observed.isStored && observed.hasObservers)
        #expect(try !declaration("computed", in: info).isStored)
        #expect(try !declaration("accessors", in: info).isStored)
        #expect(try declaration("second", in: info).isStored)
    }

    @Test func skipsLocalDeclarations() {
        let info = collect("""
        func outer() {
            struct Local {}
            func inner() {}
            let value = 1
        }
        """)
        #expect(info.scopes.map(\.name) == ["outer"])
    }

    @Test func findsEnclosingDeclarations() {
        let info = collect("""
        struct A {
            func b() {
                print(1)
            }
        }
        """)
        let names = info.declarations(containing: Position(line: 3, column: 9)).map(\.name)
        #expect(names == ["b", "A"])
    }

    @Test func detectsTopLevelCodeAndPreviews() {
        #expect(collect("print(1)").hasTopLevelCode)
        #expect(!collect("func f() {}").hasTopLevelCode)
        #expect(SyntaxCollector.collect(source: "func f() {}", path: "/x/main.swift").hasTopLevelCode)
        #expect(collect("#Preview { Text(\"\") }").previewRanges.count == 1)
    }
}

struct SymbolNameTests {
    @Test(arguments: [
        ("$s8LibTests12swiftTesting4TestfMp_17Z46c941bab82c8882fMu_", "Test"),
        ("$s8LibTests6Suite15SuitefMp_9generatorfMu_", "Suite"),
        ("$s2UI11ContentViewV5model33_46AF44A0B6E80D39F2C59D57952EDD8DLL5StatefMp_20_initialStoredValue_fMu_", "State"),
        ("$s2UI0013UIswift_ouEHafMX17_0_33_4F030B967F92D044156987BE77021EFBLl7PreviewfMf_15PreviewRegistryfMu_", "Preview"),
    ])
    func extractsMacroNames(name: String, macro: String) {
        #expect(name.expandedMacroNames.contains(macro))
    }

    @Test func ignoresOrdinaryNames() {
        #expect("$value".expandedMacroNames.isEmpty)
        #expect("Test".expandedMacroNames.isEmpty)
    }
}
