import Foundation

public enum CoreEntry {
    public static func run() {
        internalRun()
    }
}

func internalRun() {
    _ = Namespace.used
    _ = "abc".usedExtensionOnExternalType
    _ = tupleUsed

    _ = totalArea([Square(side: 2)])
    _ = describeAll([UsesDefault()])
    _ = ConformsToRedundant()
    _ = firstItem(of: IntStore())
    _ = greetPet(Dog())

    _ = describeVehicle(Car())
    _ = Sub().template()
    let point = Point(x: 1, y: 2)
    _ = point.x + point.y

    _ = useEnums()
    _ = parse("active")

    _ = try? JSONEncoder().encode(Settings(theme: "dark", fontSize: 12))
    if let incoming = try? JSONDecoder().decode(Incoming.self, from: Data()) {
        _ = incoming.id
    }
    _ = try? JSONEncoder().encode(CustomEncoding(value: 1, notEncoded: 2))
    var keys = Set<CacheKey>()
    keys.insert(CacheKey(namespace: "a", id: 1))

    let counter = Counter.shared
    counter.increment()
    _ = counter.count
    _ = counter.expensive
    var volume = Volume()
    volume.level = 11
    _ = volume.level

    _ = makeList {
        "a"
        "b"
    }
    let config = Config(values: [:])
    _ = config.theme
    let double = Multiplier(factor: 2)
    _ = double(3)

    _ = unusedParameter(used: 1, unused: 2)
    _ = underscored(1, 2)
    _ = usedInClosure(1)()
    _ = usedInOptionalBinding(nil)
    _ = usedInInterpolation("x")
    if ProcessInfo.processInfo.environment["NEVER"] != nil {
        _ = stub(1)
    }
    emptyBody(1)
    _ = ignoredParameter(1, other: 2)
    _ = [1].map(passedAsValue)
    let handler: any Handler = NoopHandler()
    handler.handle(1)
    let baseHandler: BaseHandler = SubHandler()
    baseHandler.handle(value: 1)
    _ = Initializer(unusedLabel: 1)

    _ = PublicOnlyInternal()
}
