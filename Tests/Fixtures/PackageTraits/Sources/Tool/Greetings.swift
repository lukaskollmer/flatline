func basicGreeting() -> String { "Hello" }

/// Only used when the Fancy trait is enabled.
func fancyGreeting() -> String { decorate(basicGreeting()) }

func decorate(_ text: String) -> String { "* \(text) *" }

func unusedInEveryVariant() {} // expect: unused

#if Fancy
func onlyCompiledWithFancy() {} // expect: unused
#endif
