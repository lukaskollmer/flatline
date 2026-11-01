import Foundation

struct Settings: Codable {
    var theme: String
    var fontSize: Int
}

struct Incoming: Decodable {
    let id: Int
    let ignoredField: String // expect: unused
}

struct CustomEncoding: Encodable {
    let value: Int
    let notEncoded: Int // expect: assignOnlyProperty

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct CacheKey: Hashable {
    let namespace: String
    let id: Int
}
