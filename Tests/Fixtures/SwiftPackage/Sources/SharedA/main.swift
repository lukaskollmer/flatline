// Also compiled into SharedB, which doesn't set SHARED_A.
#if SHARED_A
import ShapeExtras
#endif
import Shapes

print(makeShape(sides: 3).isTriangle)
