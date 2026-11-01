import Core

let greeter = Greeter()
print(greeter.greet("world"))
print(greeter.shout("world"))
print(makeNames())
PublicUsed().run()
_ = requiresPublicReturn()
CoreEntry.run()

let unusedTopLevel = 1 // expect: unused

func helperInMain() -> Int { 2 }
print(helperInMain())

func unusedInMain() {} // expect: unused
