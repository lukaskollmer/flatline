import FlatlineCore
import FlatlineSwift
import Foundation
import IndexStore

// Temporary development entry point.
let args = CommandLine.arguments
let lib = try IndexStoreLibrary(path: args[1])
let store = try IndexStore(path: args[2], library: lib)
var config = Configuration()
var analyzer = SwiftAnalyzer(configuration: config, projectRoot: args[3], logger: Logger(level: .verbose))
analyzer.explain = Array(args.dropFirst(4))
let result = try analyzer.analyze(stores: [store])
print(try OutputFormat.xcode.formatter().format(result.findings, context: OutputContext(projectRoot: args[3], relativePaths: true)))
for e in result.explanations { print(e) }
