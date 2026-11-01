# flatline

Finds unused code in Swift projects: Swift packages and Xcode projects or
workspaces, on macOS and Linux.

```console
$ flatline scan
* Building MyApp
* Analyzing 412 files in 9 modules
Sources/Feed/FeedLoader.swift:48:10: warning: Method 'prefetch(_:)' is unused
Sources/Feed/FeedItem.swift:12:9: warning: Property 'legacyID' is assigned, but never read
Sources/Core/Formatting.swift:31:30: warning: Parameter 'locale' is unused
Sources/Core/Theme.swift:5:10: warning: Protocol 'Themable' is redundant: it is conformed to, but never used
* Found 4 results: 1 unused, 1 redundant protocol, 1 assign-only property, 1 unused parameter (21.3s)
```

flatline replaces [Periphery](https://github.com/peripheryapp/periphery) for
our projects. It reads `.periphery.yml` and `// periphery:ignore` comments, so
switching over needs no changes (see [Migrating from Periphery](#migrating-from-periphery)).

## Installation

flatline needs a Swift 6 toolchain: Xcode 16 or later on macOS, or a
[Swift toolchain](https://www.swift.org/install/linux/) on Linux. It's tested
with Swift 6.4 (Xcode 27) on macOS and the `swift:6.4` image on Linux.

On macOS, install a prebuilt binary with Homebrew:

```bash
brew install lukaskollmer/formulae/flatline
```

Or build it from a checkout of this repository. On macOS, go through `xcrun` so
the selected Xcode's toolchain builds it, not whichever `swift` comes first on
`PATH` (e.g. a swiftly or swift.org toolchain, which may not match the SDK):

```bash
xcrun swift build -c release
```

On Linux:

```bash
swift build -c release
```

Then put the binary on your `PATH`:

```bash
cp .build/release/flatline /usr/local/bin/
```

On macOS, flatline uses the toolchain of the selected Xcode (`xcrun`), so it
honors `xcode-select`, `DEVELOPER_DIR` and `TOOLCHAINS`.

## Usage

Run `flatline scan` in the directory with your `Package.swift`,
`.xcworkspace` or `.xcodeproj`. flatline builds the project with indexing
enabled, analyzes the index, and prints results as Xcode-style warnings.

```bash
# A Swift package (built with `swift build`)
flatline scan

# An Xcode workspace or project: pick the schemes to build
flatline scan --schemes App,Widget

# Arguments after `--` go to `swift build` or `xcodebuild`
flatline scan --schemes App -- -destination 'generic/platform=iOS Simulator'

# An iOS-only Swift package: giving schemes builds it with xcodebuild
flatline scan --schemes MyPackage -- -destination 'generic/platform=iOS Simulator'

# Analyze an index store that's already there, without building
flatline scan --skip-build --index-store-path path/to/DerivedData/Index.noindex/DataStore
```

Builds of Xcode projects go to a private derived data directory
(`~/Library/Caches/flatline/DerivedData`), so they don't interfere with Xcode
and stay incremental across runs.

Test targets are built and analyzed too: code that only tests use counts as
used. Pass `--exclude-tests` to find code that only tests keep alive.

### Build variants: traits, platforms, configurations

A build compiles only one side of each `#if`: one set of package traits, one
platform, one configuration. Code that only the other side uses would look
unused. To analyze several, give each as a build variant. flatline builds each
variant into a directory of its own and analyzes them together, so a
declaration is reported only if it's unused in every variant.

```bash
# Package traits
flatline scan --variant '--traits defaults' --variant '--traits Postgres'

# An app with shared iOS and watchOS code
flatline scan --schemes App,WatchApp \
  --variant "-destination 'generic/platform=iOS Simulator'" \
  --variant "-destination 'generic/platform=watchOS Simulator'"
```

```yaml
build_variants:
  - [--traits, defaults]
  - name: postgres
    build_arguments: [--traits, Postgres]
```

Each variant's arguments are added to `build_arguments`. Swift packages build
each variant in `.build/flatline-variants/<variant>`, Xcode projects in
`<derived data>/<variant>`. If all traits can be enabled at once, a single
`flatline scan -- --enable-all-traits` is faster.

### Why is this (not) reported?

`--explain <name>` prints the chain of uses that keeps a declaration alive:

```console
$ flatline scan --skip-build --explain FeedLoader
Class 'FeedLoader' at Sources/Feed/FeedLoader.swift:8:13
  is used by property 'loader' at Sources/Feed/FeedViewModel.swift:14:9
  is used by class 'FeedViewModel' at Sources/Feed/FeedViewModel.swift:5:13
  is used by property 'body' at Sources/App/RootView.swift:9:9
  is used because it implements or overrides an external declaration ('RootView')
  is used by top-level code
```

## What flatline reports

| Kind | Example | Notes |
| --- | --- | --- |
| `unused` | `Function 'helper()' is unused` | Only the outermost unused declaration is reported; an unused type's members aren't listed separately. |
| `redundantProtocol` | `Protocol 'P' is redundant: it is conformed to, but never used` | The protocol is never used as a type or constraint, so its conformances do nothing. |
| `assignOnlyProperty` | `Property 'x' is assigned, but never read` | Stored properties without observers or property wrappers. |
| `unusedParameter` | `Parameter 'y' is unused` | Skips overrides, protocol witnesses, `@objc` methods, functions passed as values, and stubs (empty or `fatalError()` bodies). |
| `redundantPublicAccessibility` | `Method 'run()' is declared public, but not used outside of module 'Core'` | Off with `retain_public` or `disable_redundant_public_analysis`. |

### What counts as used

flatline starts from the code that runs without being referenced and marks
everything reachable from it. These are the starting points and rules:

- **Entry points:** top-level code (`main.swift`, scripts), `@main`,
  `@UIApplicationMain`, `@NSApplicationMain`.
- **Tests:** `XCTestCase` subclasses and their `test…` methods, Swift Testing
  `@Test` functions and `@Suite` types. Add other base classes (e.g.
  `QuickSpec`) with `external_test_case_classes`.
- **Overrides and protocol witnesses:** an override or protocol
  implementation is used when the overridden declaration (or requirement) and
  the type are used. Implementations of SDK protocols and overrides of SDK
  classes (e.g. `body`, `description`, `viewDidLoad`, delegate methods) are
  used whenever their type is.
- **Objective-C:** `@objc`, `@objcMembers`, `@IBAction`, `@IBOutlet`,
  `@IBInspectable`, `@IBSegueAction`, `@NSManaged` and `dynamic` declarations
  (`retain_objc_annotated`, on by default), or everything Objective-C can see
  (`retain_objc_accessible`). References from Objective-C files in the project
  count as uses.
- **Resources:** classes named in storyboards and xibs (`customClass`),
  property lists (e.g. `NSPrincipalClass`, `UISceneDelegateClassName`) and Core
  Data models.
- **Synthesized code:** stored properties read by synthesized `Encodable`
  (`retain_encodable_properties`), `Equatable` and `Hashable` conformances;
  `CodingKeys`; cases of `CaseIterable` and `Decodable` enums, and of enums
  whose `init(rawValue:)` is called.
- **Language features:** `deinit`, property wrapper members, result builder
  `build…` methods, `subscript(dynamicMember:)`, `dynamicallyCall`,
  `callAsFunction`, typealiases in protocols.
- **SwiftUI previews:** `#Preview` and `PreviewProvider` content
  (`retain_swift_ui_previews`, on by default).
- **Exports:** `@_cdecl`, `@_silgen_name`, `@_dynamicReplacement`, and
  `@available(*, unavailable)` declarations.
- **Libraries:** `public` and `open` declarations with `retain_public`.

## Comment commands

```swift
// flatline:ignore
func calledThroughReflection() {}        // not reported, and treated as used

// flatline:ignore:parameters event, context
func handle(event: Event, context: Context) {}

// flatline:ignore:all                   // anywhere in a file: ignore the whole file
```

`// periphery:ignore` and the other Periphery comment commands work the same
way. An ignore comment applies to the declaration and everything inside it,
and can be followed by an explanation: `// flatline:ignore - used by KVO`.

## Configuration

flatline reads `.flatline.yml` from the current directory (or the file passed
with `--config`). Command-line options override it. Lists also accept a single
string.

```yaml
project: App.xcworkspace
schemes: [App, Widget]
build_arguments: [-destination, "generic/platform=iOS Simulator"]

retain_files:
  - "**/Generated/**"
report_exclude:
  - Sources/Legacy/**
external_test_case_classes: [QuickSpec]

format: xcode
strict: true
```

| Key | Default | Description |
| --- | --- | --- |
| `project` | detected | `.xcworkspace`, `.xcodeproj`, or package directory. |
| `schemes` | | Xcode schemes to build. Required when a project has several. |
| `targets` | all | Report results only in these modules. |
| `exclude_targets` | | Leave these modules out of the analysis entirely. |
| `exclude_tests` | `false` | Don't build or analyze test targets. |
| `build_arguments` | | Extra arguments for `swift build` or `xcodebuild`. |
| `build_variants` | | Builds to analyze together, each a list of extra build arguments or `{name, build_arguments}`. See [Build variants](#build-variants-traits-platforms-configurations). |
| `skip_build` | `false` | Use the existing index store. |
| `clean_build` | `false` | Clean before building. |
| `index_store_path` | detected | Index stores to read. Each is analyzed as a variant of its own. |
| `derived_data_path` | private cache | Derived data directory for Xcode builds. |
| `index_store_library` | detected | Path to `libIndexStore` (also `FLATLINE_INDEXSTORE_LIBRARY`). |
| `retain_public` | `false` | Treat `public`/`open` declarations as used. Use it for libraries. |
| `retain_objc_annotated` | `true` | Treat `@objc`, `@IBAction`, … declarations as used. |
| `retain_objc_accessible` | `false` | Treat everything visible to Objective-C as used. |
| `retain_files` | | Treat everything in matching files as used. |
| `retain_swift_ui_previews` | `true` | Count `#Preview` and `PreviewProvider` content as a use. |
| `retain_codable_properties` | `false` | Treat stored properties of `Decodable` types as used. |
| `retain_encodable_properties` | `true` | Treat stored properties of `Encodable` types as used. |
| `retain_assign_only_properties` | `false` | Don't report assign-only properties. |
| `retain_assign_only_property_types` | `AnyCancellable`, `Set<AnyCancellable>`, `[AnyCancellable]`, `Cancellable`, `NSKeyValueObservation`, `NSObjectProtocol` | Types of properties that are often kept only to be retained. |
| `retain_unused_protocol_func_params` | `false` | Accepted for compatibility; protocol witnesses are never checked for unused parameters. |
| `external_encodable_protocols` | | External protocols that refine `Encodable`. |
| `external_codable_protocols` | | External protocols that refine `Codable` or `Decodable`. |
| `external_test_case_classes` | | External test base classes, besides `XCTestCase`. |
| `disable_unused_parameter_analysis` | `false` | Don't report unused parameters. |
| `disable_redundant_public_analysis` | `false` | Don't report redundant `public`. |
| `report_exclude` / `report_include` | | Globs of files to leave out of / limit results to. |
| `index_exclude` | | Globs of files to ignore entirely; their references don't count. |
| `format` | `xcode` | `xcode`, `json`, `csv`, `checkstyle`, `github-actions`, `codeclimate`. |
| `relative_results` | `false` | Print paths relative to the project root. |
| `strict` | `false` | Exit with status 1 when there are results. |
| `baseline` / `write_baseline` | | Read or write a baseline file. |
| `verbose` / `quiet` | `false` | More or less output. |

Globs are relative to the project root; `*` matches within a path component and
`**` across components.

## CI

Exit status: 0 on success, 1 with `--strict` when there are results, 2 on
errors. Results go to standard output, progress to standard error.

To adopt flatline in a project with existing findings, record them in a
baseline and fail only on new ones:

```bash
flatline scan --write-baseline .flatline-baseline.json
```

```bash
flatline scan --baseline .flatline-baseline.json --strict
```

Baselines identify results by USR, so they survive code moving around.

On GitHub Actions, `--format github-actions` annotates pull requests:

```yaml
- run: flatline scan --strict --format github-actions
```

For GitLab, `--format codeclimate` produces a Code Quality report.

## Linux

Swift packages build and analyze on Linux like on macOS. Xcode projects need
`xcodebuild`, so build them on a Mac and analyze the index store anywhere
(pass `--index-store-path` once per store to analyze several together):

```bash
flatline scan --skip-build --index-store-path DataStore
```

Paths in the index must match the checkout's paths, so analyze in the same
location the project was built in.

## Migrating from Periphery

- `.periphery.yml` is read when there's no `.flatline.yml`. Its keys mean the
  same thing; rename the file when you're ready.
- `// periphery:ignore`, `ignore:all` and `ignore:parameters` comments keep
  working.
- `periphery scan …` becomes `flatline scan …`; shared options have the same names.

Differences:

- **`retain_encodable_properties` is on by default.** Synthesized `encode(to:)`
  reads every stored property, so they're in use. Set it to `false` for
  Periphery's behavior.
- **Enums with raw values:** their cases are kept when `init(rawValue:)` is
  called on the enum, not unconditionally.
- **Synthesized `Equatable`/`Hashable`:** stored properties of such structs
  aren't reported, because the synthesized `==` and `hash(into:)` read them.
- **Not supported:** Bazel projects, unused import analysis, and the
  `setup` guide. Unsupported Periphery options in `.periphery.yml` are
  ignored with a note in `--verbose` output.

## Limitations

flatline sees what the compiler indexed in one build. Like Periphery, it can't
know about:

- Code in inactive `#if` branches (other platforms, configurations or package
  traits) unless you add them as [build variants](#build-variants-traits-platforms-configurations):
  what only they use is reported as unused.
- Dynamic uses: `NSClassFromString`, `#keyPath`/KVC strings, `Mirror`,
  `perform(_:)` with string selectors, and code loaded by name.
- Objective-C code itself: its references to Swift count, but unused
  Objective-C code isn't reported.

## How it works

1. **Build.** `swift build` or `xcodebuild` with index-while-building, so the
   compiler writes an index store: every declaration and reference, with
   relations like "contained by", "overrides" and "conforms to".
2. **Read the index.** flatline loads `libIndexStore` from the toolchain at
   runtime (`dlopen`), so one binary works with any Swift version, and reads
   the units and records of the project's files in parallel.
3. **Parse the sources.** SwiftSyntax supplies what the index lacks:
   attributes, modifiers, accessibility, comment commands, parameter usage and
   declaration ranges.
4. **Build a graph.** Declarations are nodes; "A's body or signature refers to
   B" is an edge. Members keep their type alive, extensions keep their
   extended type alive, and conditional edges model dynamic dispatch (a
   witness is used once its requirement and its type are used).
5. **Mark and report.** Everything reachable from the roots is used; the rest
   is reported.

### Code layout

| Module | Contents |
| --- | --- |
| `CIndexStore` | Function table for `libIndexStore`, loaded with `dlopen`. |
| `IndexStore` | Swift API for index stores: units, records, symbols, occurrences. |
| `FlatlineCore` | Language-independent: declaration graph, reachability, findings, configuration, output formats, baselines. |
| `FlatlineSwift` | The Swift front end: unit selection, SwiftSyntax pass, graph builder, retention rules, analyses. |
| `FlatlineProject` | Project drivers (SwiftPM, Xcode, existing index store), toolchain discovery, configuration files. |
| `flatline` | The command-line tool. |

Support for another language means a new front end that fills a
`SourceGraph`: declarations, references, roots, and conditional rules.
Reachability, reporting, configuration and output come with the core. Clang
languages write the same index store format, so a C or Objective-C front end
can reuse the `IndexStore` module.

## Development

```bash
xcrun swift test
```

(On Linux, `swift test`.)

The tests build fixture projects in `Tests/Fixtures` and compare flatline's
results with markers in their sources. A comment like `// expect: unused` or
`// expect: unusedParameter(name)` on a line means flatline must report exactly
that there; every unmarked result fails the test. To cover a new case, add the
code and its marker to a fixture.

- `Tests/Fixtures/SwiftPackage`: a package with a library, an executable,
  tests, and a macOS-only target (SwiftUI, Objective-C).
- `Tests/Fixtures/PackageTraits`: a package with code behind a trait, for
  build variants.
- `Tests/Fixtures/XcodeProject`: a macOS app with tests and a local package.
  It's generated from `project.yml`; after editing that, run `xcodegen
  generate` in that directory.

To see what the compiler indexed for a file:

```bash
flatline dump-index --index-store-path .build/out MyFile.swift
```

flatline runs on itself: `xcrun swift run flatline scan` (configured in `.flatline.yml`).

### Releasing

Set `version` in `Sources/flatline/Flatline.swift`, then publish a GitHub
release whose tag is that version (`0.2.0` or `v0.2.0`). The release workflow
builds flatline for Apple silicon and Intel, attaches the binaries to the
release, and updates the formula in
[lukaskollmer/homebrew-formulae](https://github.com/lukaskollmer/homebrew-formulae).
It needs a `GH_PAT` secret: a token with write access to this repository and
the tap.
