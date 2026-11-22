// Not reported: without the Fancy trait, Tool has no copy of value() and
// needs the one in Values.
#if !Fancy
import Values
#endif

func useValue() -> Int {
    value()
}
