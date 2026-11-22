// Also compiled into Tool, which has its own copy only with the Fancy trait.
#if VALUES || Fancy
// flatline:ignore - the copies are merged, so Tool's uses look like uses inside
// the declaring module to the redundant public analysis.
public func value() -> Int {
    1
}
#endif
