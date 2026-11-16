"Number.st: magnitudes, integers (small and large), characters."

Object subclass: #Magnitude slots: ''.
"Things that are ordered: what answers < can answer the other comparisons,
 between:and:, min: and max:. A subclass defines < and gets the rest
 (subclasses may redefine them all for speed, as SmallInteger does). No slots.
 3 max: 7 >>> 7"

Magnitude subclass: #Character slots: ''.
"A character: an immediate object (no memory of its own) whose value is a
 Unicode code point, a SmallInteger >= 0. Equal characters are the same
 object, so = is ==. Made with $a, Character value: 97 or 97 asCharacter;
 a String holds bytes and answers Characters. The tests (isLetter,
 isDigit, asUppercase...) are for ASCII only. No slots.
 $a value >>> 97"

Magnitude subclass: #Number slots: ''.
"The numbers: what all of them answer (sign, abs, even, intervals, loops,
 printing). Stratalk has integers only, SmallInteger and the large ones;
 there are no floats and no fractions. No slots."

Number subclass: #Integer slots: ''.
"The integers, small and large: factorials, gcd: and lcm:, primality,
 integer square roots, powers, printing in a base. An arithmetic result
 is a SmallInteger when it fits and a large integer when it does not, so
 the two kinds mix freely. No slots.
 (2 raisedTo: 64) class >>> LargePositiveInteger"

Integer subclass: #SmallInteger slots: ''.
"A 63-bit signed integer kept in the reference itself (immediate, no
 memory of its own), from SmallInteger minVal (-2^62) to SmallInteger
 maxVal (2^62 - 1). Arithmetic, comparisons and bit operations are VM
 primitives (1 to 18); when a result does not fit, or the argument is not
 a SmallInteger, the primitive fails and the method redoes the operation
 on large integers. // and \\ round toward minus infinity, quo: and rem:
 toward zero. No slots.
 SmallInteger maxVal + 1 >>> 4611686018427387904"

Integer byteSubclass: #LargePositiveInteger slots: ''.
"An integer >= 2^62, too big for a SmallInteger: a byte object whose
 bytes are the magnitude's digits in base 256, least significant first.
 Its subclass LargeNegativeInteger holds the integers < -2^62 the same
 way: the sign is the class. Arithmetic is done in Smalltalk, digit by
 digit, and every result that fits is made a SmallInteger again (digits:
 negative:). Bitwise operations work only on integers >= 0.
 (2 raisedTo: 64) - (2 raisedTo: 64) >>> 0"

LargePositiveInteger subclass: #LargeNegativeInteger slots: ''.
"An integer < -2^62: the bytes hold its magnitude, least significant
 first, as in LargePositiveInteger, whose methods it shares; only
 isNegative differs.
 (2 raisedTo: 64) negated class >>> LargeNegativeInteger"

"---- Magnitude ----------------------------------------------------------------"

Magnitude >> < aMagnitude [
    "Answers whether the receiver is less than aMagnitude. Each subclass
     defines it; the other comparisons are made of it."
    ^self subclassResponsibility ]
Magnitude >> > aMagnitude [
    "Answers whether the receiver is greater than aMagnitude, as aMagnitude < self.
     $c > $b >>> true"
    ^aMagnitude < self ]
Magnitude >> <= aMagnitude [
    "Answers whether the receiver is less than or equal to aMagnitude.
     $a <= $a >>> true"
    ^(aMagnitude < self) not ]
Magnitude >> >= aMagnitude [
    "Answers whether the receiver is greater than or equal to aMagnitude.
     $b >= $c >>> false"
    ^(self < aMagnitude) not ]
Magnitude >> between: min and: max [
    "Answers whether the receiver is >= min and <= max, both ends included.
     3 between: 1 and: 5 >>> true"
    ^self >= min and: [self <= max] ]
Magnitude >> min: aMagnitude [
    "Answers the smaller of the receiver and aMagnitude (aMagnitude when they are equal).
     3 min: 7 >>> 3"
    ^self < aMagnitude ifTrue: [self] ifFalse: [aMagnitude] ]
Magnitude >> max: aMagnitude [
    "Answers the greater of the receiver and aMagnitude (aMagnitude when they are equal).
     3 max: 7 >>> 7"
    ^self > aMagnitude ifTrue: [self] ifFalse: [aMagnitude] ]

"---- Number ---------------------------------------------------------------------"

Number >> isNumber [
    "Answers true: the receiver is a number.
     3 isNumber >>> true"
    ^true ]
Number >> isZero [
    "Answers whether the receiver is 0.
     5 isZero >>> false"
    ^self = 0 ]
Number >> negative [
    "Answers whether the receiver is less than 0.
     -3 negative >>> true"
    ^self < 0 ]
Number >> positive [
    "Answers whether the receiver is >= 0; 0 is positive.
     0 positive >>> true"
    ^self >= 0 ]
Number >> strictlyPositive [
    "Answers whether the receiver is greater than 0.
     0 strictlyPositive >>> false"
    ^self > 0 ]
Number >> sign [
    "Answers 1, -1 or 0: the sign of the receiver.
     -7 sign >>> -1"
    self > 0 ifTrue: [^1]. self < 0 ifTrue: [^-1]. ^0 ]
Number >> negated [
    "Answers 0 minus the receiver.
     5 negated >>> -5"
    ^0 - self ]
Number >> abs [
    "Answers the receiver's absolute value.
     -5 abs >>> 5"
    ^self < 0 ifTrue: [self negated] ifFalse: [self] ]
Number >> squared [
    "Answers the receiver times itself.
     -4 squared >>> 16"
    ^self * self ]
Number >> even [
    "Answers whether the receiver is divisible by 2.
     -4 even >>> true"
    ^(self \\ 2) = 0 ]
Number >> odd [
    "Answers whether the receiver is not divisible by 2; \\ rounds toward
     minus infinity, so negative numbers are odd as well.
     -3 odd >>> true"
    ^(self \\ 2) = 1 ]
Number >> to: stop [
    "Answers the Interval from the receiver to stop, both included, by 1.
     (1 to: 5) asArray >>> #(1 2 3 4 5)"
    ^Interval from: self to: stop by: 1 ]
Number >> to: stop by: step [
    "Answers the Interval from the receiver toward stop, by step (which may be negative).
     (1 to: 10 by: 3) asArray >>> #(1 4 7 10)"
    ^Interval from: self to: stop by: step ]
Number >> to: stop do: aBlock [
    "Runs aBlock with each integer from the receiver to stop, both included,
     counting up by 1; nothing if stop is smaller. Answers the receiver.
     | s | s := 0. 1 to: 4 do: [:i | s := s + i]. s >>> 10"
    | i |
    i := self.
    [i <= stop] whileTrue: [aBlock value: i. i := i + 1] ]
Number >> to: stop by: step do: aBlock [
    "Runs aBlock with the receiver, the receiver + step, ... as long as they
     have not passed stop (counting down if step is negative). A step of 0
     signals an Error. Answers the receiver.
     | a | a := OrderedCollection new. 10 to: 1 by: -4 do: [:i | a add: i]. a >>> OrderedCollection (10 6 2)"
    | i |
    step = 0 ifTrue: [^self error: 'a step of 0 never ends'].
    i := self.
    step > 0
        ifTrue: [[i <= stop] whileTrue: [aBlock value: i. i := i + step]]
        ifFalse: [[i >= stop] whileTrue: [aBlock value: i. i := i + step]] ]
Number >> timesRepeat: aBlock [
    "Runs aBlock (no arguments) as many times as the receiver says; nothing
     if it is < 1. Answers the receiver.
     | n | n := 0. 3 timesRepeat: [n := n + 2]. n >>> 6"
    | i |
    i := 1.
    [i <= self] whileTrue: [aBlock value. i := i + 1] ]
Number >> @ y [
    "Answers the Point with the receiver as x and y as y.
     3 @ 4 >>> 3@4"
    ^Point x: self y: y ]
Number >> printOn: aStream [
    "Writes the receiver's decimal digits on aStream.
     | w | w := WriteStream on: String new. 42 printOn: w. w contents >>> '42'"
    aStream nextPutAll: (self printString: 10) ]
Number >> printString [
    "Answers the receiver's decimal digits, with a - before them if it is negative.
     -42 printString >>> '-42'"
    ^self printString: 10 ]
Number >> displayString [
    "Answers the same as printString: a number is displayed as it is printed.
     42 displayString >>> '42'"
    ^self printString ]

"---- Integer -------------------------------------------------------------------"

Integer >> isInteger [
    "Answers true: the receiver is an integer.
     3 isInteger >>> true"
    ^true ]
Integer >> factorial [
    "Answers the product of the integers from 1 to the receiver (1 for 0 and 1),
     large if it does not fit. Signals an Error for a negative receiver.
     10 factorial >>> 3628800"
    | r |
    self < 0 ifTrue: [^self error: 'factorial of a negative number'].
    r := 1.
    2 to: self do: [:i | r := r * i].
    ^r ]
Integer >> gcd: anInteger [
    "Answers the greatest common divisor of the receiver and anInteger, >= 0
     (Euclid's algorithm on their absolute values); 0 gcd: n is n abs.
     12 gcd: -18 >>> 6"
    | a b t |
    a := self abs. b := anInteger abs.
    [b = 0] whileFalse: [t := a \\ b. a := b. b := t].
    ^a ]
Integer >> lcm: anInteger [
    "Answers the least common multiple of the receiver and anInteger, >= 0;
     0 when either is 0.
     4 lcm: 6 >>> 12"
    (self = 0 or: [anInteger = 0]) ifTrue: [^0].
    ^(self * anInteger) abs // (self gcd: anInteger) ]
Integer >> isPrime [
    "Answers whether the receiver is a prime, by trial division up to its
     square root; false for everything below 2.
     97 isPrime >>> true"
    | i |
    self < 2 ifTrue: [^false].
    i := 2.
    [i * i <= self] whileTrue: [(self \\ i) = 0 ifTrue: [^false]. i := i + 1].
    ^true ]
Integer >> fib [
    "Answers the receiver's Fibonacci number (0 fib is 0, 1 fib is 1),
     computed by the doubly recursive definition: a benchmark, slow on purpose.
     A receiver below 2 answers itself.
     10 fib >>> 55"
    self < 2 ifTrue: [^self]. ^(self - 1) fib + (self - 2) fib ]
Integer >> sqrtFloor [
    "Answers the greatest integer whose square is <= the receiver (Newton's
     method in integers, so large receivers work). Signals an Error for a
     negative receiver.
     17 sqrtFloor >>> 4"
    | x y |
    self < 0 ifTrue: [^self error: 'square root of a negative number'].
    self < 2 ifTrue: [^self].
    x := self. y := (x + 1) // 2.
    [y < x] whileTrue: [x := y. y := (x + (self // x)) // 2].
    ^x ]
Integer >> raisedTo: n [
    "Answers the receiver to the power n, an integer >= 0 (by squaring;
     large if it does not fit). Signals an Error for a negative n.
     2 raisedTo: 70 >>> 1180591620717411303424"
    | r b e |
    n < 0 ifTrue: [^self error: 'negative exponent'].
    r := 1. b := self. e := n.
    [e > 0] whileTrue: [
        (e bitAnd: 1) = 1 ifTrue: [r := r * b].
        e := e bitShift: -1.
        e > 0 ifTrue: [b := b * b]].
    ^r ]
Integer >> asCharacter [
    "Answers the Character whose code point is the receiver; signals an
     Error if it is negative.
     97 asCharacter >>> $a"
    ^Character value: self ]
Integer >> asInteger [
    "Answers the receiver.
     5 asInteger >>> 5"
    ^self ]
Integer >> printString: base [
    "Answers the receiver's digits in base (2 to 36; digits past 9 are
     capital letters), with a - before them if it is negative.
     255 printString: 2 >>> '11111111'"
    | n s digits |
    self = 0 ifTrue: [^'0'].
    s := WriteStream on: (String new: 24).
    n := self abs.
    digits := OrderedCollection new.
    [n = 0] whileFalse: [digits addFirst: (n \\ base). n := n // base].
    self < 0 ifTrue: [s nextPut: $-].
    digits do: [:d | s nextPut: (Character digitValue: d)].
    ^s contents ]
Integer >> printString: base length: n [
    "Answers printString: base padded on the left with 0s to n characters
     (not cut if longer), after the minus sign of a negative number.
     -5 printString: 10 length: 4 >>> '-005'"
    | s |
    self < 0 ifTrue: [^'-' , (self negated printString: base length: n - 1)].
    s := self printString: base.
    ^(String new: (n - s size max: 0) withAll: $0), s ]
Integer >> hex [
    "Answers the receiver's digits in base 16, capital letters, no prefix.
     -255 hex >>> '-FF'"
    ^self printString: 16 ]
Integer >> isLarge [
    "Answers whether the receiver is a large integer (LargePositiveInteger
     or LargeNegativeInteger) rather than a SmallInteger.
     3 isLarge >>> false"
    ^false ]

"---- SmallInteger: the VM does these, and fails to a slower path ----------"

SmallInteger >> + n [
    "Answers the sum. A VM primitive (1); on overflow, or when n is not a
     SmallInteger, it is done on large integers (an Error if n is not an integer).
     SmallInteger maxVal + 1 >>> 4611686018427387904"
    <primitive: 1> ^self largeOp: #+ with: n ]
SmallInteger >> - n [
    "Answers the difference. A VM primitive (2); on overflow, or for a large
     n, it is done on large integers.
     3 - 10 >>> -7"
    <primitive: 2> ^self largeOp: #- with: n ]
SmallInteger >> < n [
    "Answers whether the receiver is less than n. A VM primitive (3); a large
     n is compared as large integers, a non-integer signals an Error.
     3 < 4 >>> true"
    <primitive: 3> ^self largeCompare: #< with: n ]
SmallInteger >> > n [
    "Answers whether the receiver is greater than n. A VM primitive (4).
     3 > 4 >>> false"
    <primitive: 4> ^self largeCompare: #> with: n ]
SmallInteger >> <= n [
    "Answers whether the receiver is less than or equal to n. A VM primitive (5).
     3 <= 3 >>> true"
    <primitive: 5> ^self largeCompare: #<= with: n ]
SmallInteger >> >= n [
    "Answers whether the receiver is greater than or equal to n. A VM primitive (6).
     3 >= 4 >>> false"
    <primitive: 6> ^self largeCompare: #>= with: n ]
SmallInteger >> = n [
    "Answers whether n is the same integer. A VM primitive (7); anything
     that is not a number is not equal (no Error).
     3 = 'three' >>> false"
    <primitive: 7> ^n isNumber and: [self largeCompare: #= with: n] ]
SmallInteger >> ~= n [
    "Answers whether n is not the same integer. A VM primitive (8).
     3 ~= 4 >>> true"
    <primitive: 8> ^(self = n) not ]
SmallInteger >> * n [
    "Answers the product. A VM primitive (9); on overflow, or for a large n,
     it is done on large integers.
     6 * 7 >>> 42"
    <primitive: 9> ^self largeOp: #* with: n ]
SmallInteger >> / n [
    "Answers the exact quotient. A VM primitive (10) when n divides the
     receiver; there are no fractions, so an inexact division signals an
     Error, and n = 0 signals ZeroDivide.
     6 / 3 >>> 2"
    <primitive: 10>
    n = 0 ifTrue: [^ZeroDivide new signal: 'division by zero'].
    (n isInteger and: [(self \\ n) = 0]) ifTrue: [^self // n].
    ^self error: 'fractions are not supported' ]
SmallInteger >> \\ n [
    "Answers the remainder of // : the modulo, which has the sign of n (or is 0).
     A VM primitive (11); signals ZeroDivide if n is 0.
     -7 \\ 2 >>> 1"
    <primitive: 11>
    n = 0 ifTrue: [^ZeroDivide new signal: 'division by zero'].
    ^self largeOp: #\\ with: n ]
SmallInteger >> // n [
    "Answers the quotient rounded toward minus infinity (floor division).
     A VM primitive (12); signals ZeroDivide if n is 0.
     -7 // 2 >>> -4"
    <primitive: 12>
    n = 0 ifTrue: [^ZeroDivide new signal: 'division by zero'].
    ^self largeOp: #// with: n ]
SmallInteger >> quo: n [
    "Answers the quotient rounded toward zero (truncated division).
     A VM primitive (13); signals ZeroDivide if n is 0.
     -7 quo: 2 >>> -3"
    <primitive: 13>
    n = 0 ifTrue: [^ZeroDivide new signal: 'division by zero'].
    ^self largeOp: #quo: with: n ]
SmallInteger >> rem: n [
    "Answers the remainder of quo: , which has the sign of the receiver (or is 0).
     A VM primitive (14); signals ZeroDivide if n is 0.
     -7 rem: 2 >>> -1"
    <primitive: 14>
    n = 0 ifTrue: [^ZeroDivide new signal: 'division by zero'].
    ^self largeOp: #rem: with: n ]
SmallInteger >> bitAnd: n [
    "Answers the bitwise and, in two's complement. A VM primitive (15); with a
     large n it is done on large integers (both must then be >= 0).
     12 bitAnd: 10 >>> 8"
    <primitive: 15> ^self largeOp: #bitAnd: with: n ]
SmallInteger >> bitOr: n [
    "Answers the bitwise or, in two's complement. A VM primitive (16).
     12 bitOr: 3 >>> 15"
    <primitive: 16> ^self largeOp: #bitOr: with: n ]
SmallInteger >> bitXor: n [
    "Answers the bitwise exclusive or, in two's complement. A VM primitive (17).
     5 bitXor: 3 >>> 6"
    <primitive: 17> ^self largeOp: #bitXor: with: n ]
SmallInteger >> bitShift: n [
    "Answers the receiver shifted left by n bits (right if n is negative,
     keeping the sign: a floor division by a power of 2). A VM primitive (18);
     a result that does not fit is made on large integers.
     -16 bitShift: -2 >>> -4"
    <primitive: 18> ^self largeOp: #bitShift: with: n ]
SmallInteger >> printString [
    "Answers the receiver's decimal digits. A VM primitive (19).
     -42 printString >>> '-42'"
    <primitive: 19> ^self printString: 10 ]
SmallInteger >> printOn: aStream [
    "Writes the receiver's decimal digits on aStream."
    aStream nextPutAll: self printString ]
SmallInteger >> identityHash [
    "Answers the receiver itself.
     42 identityHash >>> 42"
    ^self ]
SmallInteger >> hash [
    "Answers the receiver itself.
     42 hash >>> 42"
    ^self ]
SmallInteger >> largeOp: aSymbol with: n [
    "Answers the arithmetic operation aSymbol done on the receiver made large
     and n: the slow path when a primitive fails. Signals an Error if n is not
     an integer.
     3 + 'x' >>> Error: an integer was expected, not 'x'"
    n isInteger ifFalse: [^self error: 'an integer was expected, not ', n printString].
    ^(LargePositiveInteger fromInteger: self) perform: aSymbol with: n ]
SmallInteger >> largeCompare: aSymbol with: n [
    "Answers the comparison aSymbol done on the receiver made large and n:
     the slow path when a comparison primitive fails. Signals an Error if n is
     not an integer."
    n isInteger ifFalse: [^self error: 'an integer was expected, not ', n printString].
    ^(LargePositiveInteger fromInteger: self) perform: aSymbol with: n ]
SmallInteger >> shallowCopy [
    "Answers the receiver: an immediate integer is its own copy.
     3 shallowCopy >>> 3"
    ^self ]
SmallInteger >> deepCopy [
    "Answers the receiver: an immediate integer is its own copy.
     3 deepCopy >>> 3"
    ^self ]
SmallInteger class >> maxVal [
    "The greatest SmallInteger, 2^62 - 1; one more is a LargePositiveInteger.
     SmallInteger maxVal >>> 4611686018427387903"
    ^4611686018427387903 ]
SmallInteger class >> minVal [
    "The smallest SmallInteger, -2^62; one less is a LargeNegativeInteger.
     SmallInteger minVal >>> -4611686018427387904"
    ^-4611686018427387904 ]

"---- large integers: bytes, least significant first; the sign is the class ----"

LargePositiveInteger class >> fromInteger: n [
    "Answers n as a large integer (a SmallInteger or a large one), not made
     small again even if it fits: what the slow paths compute on.
     (LargePositiveInteger fromInteger: 300) digits >>> #(44 1)"
    | m bytes r i |
    n isLarge ifTrue: [^n].
    n = SmallInteger minVal ifTrue: [r := LargeNegativeInteger basicNew: 8. r digitAt: 8 put: 64. ^r].
    m := n abs.
    bytes := OrderedCollection new.
    [m = 0] whileFalse: [bytes add: (m bitAnd: 255). m := m bitShift: -8].
    r := (n < 0 ifTrue: [LargeNegativeInteger] ifFalse: [LargePositiveInteger]) basicNew: bytes size.
    i := 1.
    bytes do: [:b | r digitAt: i put: b. i := i + 1].
    ^r ]
LargePositiveInteger class >> digits: aCollection negative: aBoolean [
    "Answers the integer of these bytes (least significant first) and sign,
     made a SmallInteger if it fits; high zero bytes are dropped.
     LargePositiveInteger digits: #(1 1) negative: true >>> -257"
    | n r |
    n := aCollection size.
    [n > 0 and: [(aCollection at: n) = 0]] whileTrue: [n := n - 1].
    (n = 8 and: [aBoolean and: [(aCollection at: 8) = 64 and: [(1 to: 7) allSatisfy: [:i | (aCollection at: i) = 0]]]])
        ifTrue: [^SmallInteger minVal].
    (n <= 7 or: [n = 8 and: [(aCollection at: 8) < 64]]) ifTrue: [
        r := 0.
        n to: 1 by: -1 do: [:i | r := (r bitShift: 8) + (aCollection at: i)].
        ^aBoolean ifTrue: [0 - r] ifFalse: [r]].
    r := (aBoolean ifTrue: [LargeNegativeInteger] ifFalse: [LargePositiveInteger]) basicNew: n.
    1 to: n do: [:i | r digitAt: i put: (aCollection at: i)].
    ^r ]
LargePositiveInteger >> isLarge [
    "Answers true: the receiver is a large integer.
     (2 raisedTo: 70) isLarge >>> true"
    ^true ]
LargePositiveInteger >> digitAt: i [
    "Answers the receiver's byte i (1 is the least significant), 0 past the
     last one. A VM primitive (44, basicAt:).
     (2 raisedTo: 64) digitAt: 9 >>> 1"
    <primitive: 44> ^0 ]
LargePositiveInteger >> digitAt: i put: b [
    "Sets the receiver's byte i to b (0 to 255). A VM primitive (45,
     basicAt:put:); only for building a new large integer."
    <primitive: 45> ]
LargePositiveInteger >> digitLength [
    "The number of bytes of the receiver's magnitude.
     (2 raisedTo: 64) digitLength >>> 9"
    ^self basicSize ]
LargePositiveInteger >> isNegative [
    "Answers false: a LargePositiveInteger is positive.
     (2 raisedTo: 64) isNegative >>> false"
    ^false ]
LargeNegativeInteger >> isNegative [
    "Answers true: a LargeNegativeInteger is negative.
     (2 raisedTo: 64) negated isNegative >>> true"
    ^true ]
LargePositiveInteger >> digits [
    "Answers the receiver's magnitude bytes, least significant first, as an Array.
     (2 raisedTo: 64) digits >>> #(0 0 0 0 0 0 0 0 1)"
    | d |
    d := Array new: self digitLength.
    1 to: d size do: [:i | d at: i put: (self digitAt: i)].
    ^d ]
LargePositiveInteger >> negated [
    "Answers the integer of the same magnitude and the other sign.
     (2 raisedTo: 64) negated >>> -18446744073709551616"
    ^LargePositiveInteger digits: self digits negative: self isNegative not ]
LargePositiveInteger >> abs [
    "Answers the receiver's magnitude, as a positive integer.
     (2 raisedTo: 64) negated abs >>> 18446744073709551616"
    ^LargePositiveInteger digits: self digits negative: false ]
LargePositiveInteger >> < n [
    "Answers whether the receiver is less than the integer n.
     (2 raisedTo: 64) < (2 raisedTo: 65) >>> true"
    ^(self compare: n) < 0 ]
LargePositiveInteger >> > n [
    "Answers whether the receiver is greater than the integer n.
     (2 raisedTo: 64) > 5 >>> true"
    ^(self compare: n) > 0 ]
LargePositiveInteger >> <= n [
    "Answers whether the receiver is less than or equal to the integer n.
     (2 raisedTo: 64) negated <= 5 >>> true"
    ^(self compare: n) <= 0 ]
LargePositiveInteger >> >= n [
    "Answers whether the receiver is greater than or equal to the integer n.
     (2 raisedTo: 64) >= (2 raisedTo: 64) >>> true"
    ^(self compare: n) >= 0 ]
LargePositiveInteger >> = n [
    "Answers whether n is an integer of the same value; anything else is
     not equal.
     (2 raisedTo: 64) = (2 raisedTo: 64) >>> true"
    ^n isInteger and: [(self compare: n) = 0] ]
LargePositiveInteger >> hash [
    "Answers a hash made of the two lowest bytes of the magnitude.
     ((2 raisedTo: 64) + 258) hash >>> 258"
    ^(self digitAt: 1) + ((self digitAt: 2) * 256) ]
LargePositiveInteger >> compare: n [
    "Answers -1, 0 or 1 as the receiver is less than, equal to or greater
     than the integer n (small or large).
     (2 raisedTo: 64) negated compare: 5 >>> -1"
    | a b c |
    a := self. b := LargePositiveInteger fromInteger: n.
    a isNegative ~= b isNegative ifTrue: [^a isNegative ifTrue: [-1] ifFalse: [1]].
    c := LargePositiveInteger compareDigits: a digits with: b digits.
    ^a isNegative ifTrue: [0 - c] ifFalse: [c] ]
LargePositiveInteger class >> compareDigits: a with: b [
    "Answers -1, 0 or 1 as the magnitude of the digit Array a (least
     significant first) is less than, equal to or greater than b's.
     LargePositiveInteger compareDigits: #(1 2) with: #(5 1) >>> 1"
    | n x y |
    n := a size max: b size.
    n to: 1 by: -1 do: [:i |
        x := i <= a size ifTrue: [a at: i] ifFalse: [0].
        y := i <= b size ifTrue: [b at: i] ifFalse: [0].
        x < y ifTrue: [^-1].
        x > y ifTrue: [^1]].
    ^0 ]
LargePositiveInteger class >> addDigits: a to: b [
    "Answers the digit Array of the sum of two magnitudes given as digit
     Arrays, least significant first; one digit longer than the longer of them.
     LargePositiveInteger addDigits: #(255 1) to: #(1) >>> #(0 2 0)"
    | n r carry s |
    n := (a size max: b size) + 1.
    r := Array new: n.
    carry := 0.
    1 to: n do: [:i |
        s := carry + (i <= a size ifTrue: [a at: i] ifFalse: [0]) + (i <= b size ifTrue: [b at: i] ifFalse: [0]).
        r at: i put: (s bitAnd: 255).
        carry := s bitShift: -8].
    ^r ]
LargePositiveInteger class >> subtractDigits: b from: a [
    "Answers the digit Array of a - b, for magnitudes given as digit Arrays
     (least significant first) with a >= b; as long as a.
     LargePositiveInteger subtractDigits: #(1) from: #(0 1) >>> #(255 0)"
    | r borrow s |
    r := Array new: a size.
    borrow := 0.
    1 to: a size do: [:i |
        s := (a at: i) - borrow - (i <= b size ifTrue: [b at: i] ifFalse: [0]).
        s < 0 ifTrue: [s := s + 256. borrow := 1] ifFalse: [borrow := 0].
        r at: i put: s].
    ^r ]
LargePositiveInteger class >> multiplyDigits: a by: b [
    "Answers the digit Array of the product of two magnitudes given as digit
     Arrays, least significant first (schoolbook multiplication).
     LargePositiveInteger multiplyDigits: #(255) by: #(255) >>> #(1 254)"
    | r carry k t |
    r := Array new: a size + b size withAll: 0.
    1 to: a size do: [:i |
        carry := 0.
        1 to: b size do: [:j |
            k := i + j - 1.
            t := (r at: k) + ((a at: i) * (b at: j)) + carry.
            r at: k put: (t bitAnd: 255).
            carry := t bitShift: -8].
        k := i + b size.
        [carry > 0] whileTrue: [
            t := (r at: k) + carry.
            r at: k put: (t bitAnd: 255).
            carry := t bitShift: -8.
            k := k + 1]].
    ^r ]
LargePositiveInteger class >> divideDigits: a by: d [
    "Answers {quotient digits. remainder} of the magnitude a (a digit Array,
     least significant first) divided by a small integer d > 0.
     LargePositiveInteger divideDigits: #(1 1) by: 2 >>> #(#(128 0) 1)"
    | q r t |
    q := Array new: a size.
    r := 0.
    a size to: 1 by: -1 do: [:i |
        t := (r bitShift: 8) + (a at: i).
        q at: i put: t // d.
        r := t \\ d].
    ^Array with: q with: r ]
LargePositiveInteger >> + n [
    "Answers the sum with the integer n, made small if it fits.
     (2 raisedTo: 64) + (2 raisedTo: 64) >>> 36893488147419103232"
    | a b c |
    a := self. b := LargePositiveInteger fromInteger: n.
    a isNegative = b isNegative ifTrue: [
        ^LargePositiveInteger digits: (LargePositiveInteger addDigits: a digits to: b digits) negative: a isNegative].
    c := LargePositiveInteger compareDigits: a digits with: b digits.
    c = 0 ifTrue: [^0].
    c > 0 ifTrue: [^LargePositiveInteger digits: (LargePositiveInteger subtractDigits: b digits from: a digits) negative: a isNegative].
    ^LargePositiveInteger digits: (LargePositiveInteger subtractDigits: a digits from: b digits) negative: b isNegative ]
LargePositiveInteger >> - n [
    "Answers the difference with the integer n, made small if it fits.
     (2 raisedTo: 64) - 1 >>> 18446744073709551615"
    ^self + (LargePositiveInteger fromInteger: n) negated ]
LargePositiveInteger >> * n [
    "Answers the product with the integer n.
     (2 raisedTo: 64) * -3 >>> -55340232221128654848"
    | b |
    b := LargePositiveInteger fromInteger: n.
    ^LargePositiveInteger digits: (LargePositiveInteger multiplyDigits: self digits by: b digits)
        negative: self isNegative ~= b isNegative ]
LargePositiveInteger >> divmod: n [
    "Answers {quotient. remainder} of a division by the integer n rounding
     toward zero: what quo: and rem: answer. Divides digit by digit when |n|
     is below 128, bit by bit otherwise. Signals ZeroDivide if n is 0.
     (2 raisedTo: 64) negated divmod: 1000 >>> #(-18446744073709551 -616)"
    | b q r rem one |
    b := (LargePositiveInteger fromInteger: n) abs.
    b = 0 ifTrue: [^ZeroDivide new signal: 'division by zero'].
    (b isLarge not and: [b < 128]) ifTrue: [
        r := LargePositiveInteger divideDigits: self digits by: b.
        q := LargePositiveInteger digits: (r at: 1) negative: self isNegative ~= n negative.
        rem := r at: 2.
        ^Array with: q with: (self isNegative ifTrue: [0 - rem] ifFalse: [rem])].
    "long division, one bit at a time"
    q := 0. rem := 0. one := 1.
    (self digitLength * 8) to: 1 by: -1 do: [:bit |
        rem := (rem * 2) + ((self abs bitAt: bit)).
        q := q * 2.
        rem >= b ifTrue: [rem := rem - b. q := q + 1]].
    self isNegative ~= n negative ifTrue: [q := q negated].
    self isNegative ifTrue: [rem := rem negated].
    ^Array with: q with: rem ]
LargePositiveInteger >> bitAt: i [
    "Answers bit i of the receiver's magnitude (1 is the lowest), 0 or 1.
     (2 raisedTo: 64) bitAt: 65 >>> 1"
    ^((self digitAt: (i - 1) // 8 + 1) bitShift: 0 - ((i - 1) \\ 8)) bitAnd: 1 ]
LargePositiveInteger >> quo: n [
    "Answers the quotient by the integer n rounded toward zero. Signals
     ZeroDivide if n is 0.
     (2 raisedTo: 64) quo: -7 >>> -2635249153387078802"
    ^(self divmod: n) at: 1 ]
LargePositiveInteger >> rem: n [
    "Answers the remainder of quo: , with the sign of the receiver (or 0).
     (2 raisedTo: 64) rem: -7 >>> 2"
    ^(self divmod: n) at: 2 ]
LargePositiveInteger >> // n [
    "Answers the quotient by the integer n rounded toward minus infinity.
     Signals ZeroDivide if n is 0.
     (2 raisedTo: 64) // -7 >>> -2635249153387078803"
    | qr |
    qr := self divmod: n.
    ((qr at: 2) ~= 0 and: [self negative ~= n negative]) ifTrue: [^(qr at: 1) - 1].
    ^qr at: 1 ]
LargePositiveInteger >> \\ n [
    "Answers the remainder of // : the modulo, with the sign of n (or 0).
     (2 raisedTo: 64) \\ -7 >>> -5"
    | r |
    r := (self divmod: n) at: 2.
    (r ~= 0 and: [r negative ~= n negative]) ifTrue: [^r + n].
    ^r ]
LargePositiveInteger >> / n [
    "Answers the exact quotient by the integer n; an inexact division signals
     an Error (there are no fractions), n = 0 ZeroDivide.
     (2 raisedTo: 64) / 1024 >>> 18014398509481984"
    (self \\ n) = 0 ifTrue: [^self // n].
    ^self error: 'fractions are not supported' ]
LargePositiveInteger >> negative [
    "Answers whether the receiver is negative, from its class.
     (2 raisedTo: 64) negated negative >>> true"
    ^self isNegative ]
LargePositiveInteger >> bitShift: n [
    "Answers the receiver shifted left by n bits (a multiplication by 2^n),
     or right if n is negative (a floor division, keeping the sign).
     (2 raisedTo: 64) bitShift: -60 >>> 16"
    n >= 0 ifTrue: [^self * (2 raisedTo: n)].
    ^self // (2 raisedTo: 0 - n) ]
LargePositiveInteger >> bitOp: n with: aBlock [
    "Answers the integer whose bytes are aBlock applied to the receiver's
     and n's bytes, pair by pair: the bitwise operations. Signals an Error
     if either is negative."
    | a b r |
    (self negative or: [n negative]) ifTrue: [^self error: 'bitwise operations of negative large integers are not supported'].
    a := self digits. b := (LargePositiveInteger fromInteger: n) digits.
    r := Array new: (a size max: b size).
    1 to: r size do: [:i |
        r at: i put: (aBlock value: (i <= a size ifTrue: [a at: i] ifFalse: [0]) value: (i <= b size ifTrue: [b at: i] ifFalse: [0]))].
    ^LargePositiveInteger digits: r negative: false ]
LargePositiveInteger >> bitAnd: n [
    "Answers the bitwise and with the integer n; both must be >= 0.
     ((2 raisedTo: 64) + 5) bitAnd: 255 >>> 5"
    ^self bitOp: n with: [:x :y | x bitAnd: y] ]
LargePositiveInteger >> bitOr: n [
    "Answers the bitwise or with the integer n; both must be >= 0.
     (2 raisedTo: 64) bitOr: 1 >>> 18446744073709551617"
    ^self bitOp: n with: [:x :y | x bitOr: y] ]
LargePositiveInteger >> bitXor: n [
    "Answers the bitwise exclusive or with the integer n; both must be >= 0.
     (2 raisedTo: 64) bitXor: (2 raisedTo: 64) >>> 0"
    ^self bitOp: n with: [:x :y | x bitXor: y] ]
LargePositiveInteger >> printString: base [
    "Answers the receiver's digits in base (2 to 36), with a - before them if
     it is negative.
     (2 raisedTo: 64) printString: 16 >>> '10000000000000000'"
    | digits n s qr |
    digits := OrderedCollection new.
    n := self abs.
    [n isLarge] whileTrue: [
        qr := LargePositiveInteger divideDigits: n digits by: base.
        digits addFirst: (qr at: 2).
        n := LargePositiveInteger digits: (qr at: 1) negative: false].
    s := WriteStream on: (String new: 32).
    self isNegative ifTrue: [s nextPut: $-].
    s nextPutAll: (n printString: base).
    digits do: [:d | s nextPut: (Character digitValue: d)].
    ^s contents ]
LargePositiveInteger >> printOn: aStream [
    "Writes the receiver's decimal digits on aStream.
     | w | w := WriteStream on: String new. (2 raisedTo: 64) printOn: w. w contents >>> '18446744073709551616'"
    aStream nextPutAll: (self printString: 10) ]
LargePositiveInteger >> printString [
    "Answers the receiver's decimal digits.
     (2 raisedTo: 64) negated printString >>> '-18446744073709551616'"
    ^self printString: 10 ]
LargePositiveInteger >> shallowCopy [
    "Answers the receiver: a large integer is never changed once made, so it
     is not copied.
     (2 raisedTo: 64) shallowCopy >>> 18446744073709551616"
    ^self ]

"---- Character: immediate; the value is a Unicode code point ------------------"

Character class >> value: anInteger [
    "Answers the Character whose code point is anInteger. A VM primitive (31);
     signals an Error if anInteger is not a SmallInteger >= 0.
     Character value: 65 >>> $A"
    <primitive: 31> ^self error: 'not a character code' ]
Character class >> digitValue: n [
    "Answers the character of the digit n, 0 to 35: 0 to 9, then A to Z.
     Character digitValue: 11 >>> $B"
    ^'0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ' at: n + 1 ]
Character class >> cr [
    "The end of a line: a line feed (10), as StrataOS ends lines, the same as lf.
     Character cr value >>> 10"
    ^Character value: 10 ]
Character class >> lf [
    "The line feed (10).
     Character lf value >>> 10"
    ^Character value: 10 ]
Character class >> tab [
    "The horizontal tab (9).
     Character tab value >>> 9"
    ^Character value: 9 ]
Character class >> space [
    "The space (32).
     Character space value >>> 32"
    ^Character value: 32 ]
Character class >> nul [
    "The NUL character (0).
     Character nul value >>> 0"
    ^Character value: 0 ]
Character class >> escape [
    "The escape character (27), which starts terminal escape sequences.
     Character escape value >>> 27"
    ^Character value: 27 ]
Character class >> backspace [
    "The backspace (8).
     Character backspace value >>> 8"
    ^Character value: 8 ]
Number >> isLiteral [
    "Answers true: a number can be written inside an array literal.
     #(1 -2) isLiteral >>> true"
    ^true ]
Character >> isLiteral [
    "Answers true: a Character can be written inside an array literal.
     $a isLiteral >>> true"
    ^true ]
Character >> value [
    "The receiver's code point. A VM primitive (30).
     $a value >>> 97"
    <primitive: 30> ]
Character >> asInteger [
    "The receiver's code point, as value. A VM primitive (30).
     $A asInteger >>> 65"
    <primitive: 30> ]
Character >> asCharacter [
    "Answers the receiver.
     $a asCharacter >>> $a"
    ^self ]
Character >> isCharacter [
    "Answers true: the receiver is a Character.
     $a isCharacter >>> true"
    ^true ]
Character >> = aChar [
    "Answers whether aChar is the same character; characters are immediate,
     so this is identity.
     $a = $a >>> true"
    ^self == aChar ]
Character >> hash [
    "Answers the receiver's code point.
     $a hash >>> 97"
    ^self value ]
Character >> < aChar [
    "Answers whether the receiver's code point is below aChar's.
     $a < $b >>> true"
    ^self value < aChar value ]
Character >> > aChar [
    "Answers whether the receiver's code point is above aChar's.
     $a > $B >>> true"
    ^self value > aChar value ]
Character >> <= aChar [
    "Answers whether the receiver's code point is at most aChar's.
     $a <= $a >>> true"
    ^self value <= aChar value ]
Character >> >= aChar [
    "Answers whether the receiver's code point is at least aChar's.
     $a >= $b >>> false"
    ^self value >= aChar value ]
Character >> isVowel [
    "Answers whether the receiver is one of a e i o u, either case.
     $E isVowel >>> true"
    ^'aeiouAEIOU' includes: self ]
Character >> isLetter [
    "Answers whether the receiver is an ASCII letter, A to Z or a to z.
     $q isLetter >>> true"
    ^self isUppercase or: [self isLowercase] ]
Character >> isUppercase [
    "Answers whether the receiver is an ASCII capital letter, A to Z.
     $a isUppercase >>> false"
    ^self value between: 65 and: 90 ]
Character >> isLowercase [
    "Answers whether the receiver is an ASCII small letter, a to z.
     $a isLowercase >>> true"
    ^self value between: 97 and: 122 ]
Character >> isDigit [
    "Answers whether the receiver is a decimal digit, 0 to 9.
     $7 isDigit >>> true"
    ^self value between: 48 and: 57 ]
Character >> isAlphaNumeric [
    "Answers whether the receiver is an ASCII letter or a digit.
     $_ isAlphaNumeric >>> false"
    ^self isLetter or: [self isDigit] ]
Character >> isSeparator [
    "Answers whether the receiver is white space: a space, or a code point
     from 9 to 13 (tab, line feed, vertical tab, form feed, carriage return).
     Character tab isSeparator >>> true"
    ^self value = 32 or: [self value between: 9 and: 13] ]
Character >> isPunctuation [
    "Answers whether the receiver is one of . , : ; ! ?
     $; isPunctuation >>> true"
    ^'.,:;!?' includes: self ]
Character >> digitValue [
    "Answers the value of the receiver as a digit: 0 to 9 for the digits,
     10 to 35 for the letters of either case; -1 for anything else.
     $f digitValue >>> 15"
    self isDigit ifTrue: [^self value - 48].
    self isUppercase ifTrue: [^self value - 55].
    self isLowercase ifTrue: [^self value - 87].
    ^-1 ]
Character >> asUppercase [
    "Answers the capital letter of an ASCII small letter, the receiver otherwise.
     $a asUppercase >>> $A"
    ^self isLowercase ifTrue: [Character value: self value - 32] ifFalse: [self] ]
Character >> asLowercase [
    "Answers the small letter of an ASCII capital letter, the receiver otherwise.
     $Q asLowercase >>> $q"
    ^self isUppercase ifTrue: [Character value: self value + 32] ifFalse: [self] ]
Character >> asString [
    "Answers a new String of the receiver alone.
     $a asString >>> 'a'"
    ^String with: self ]
Character >> asSymbol [
    "Answers the Symbol of the receiver alone.
     $a asSymbol >>> #a"
    ^self asString asSymbol ]
Character >> printOn: aStream [
    "Writes the receiver as a literal on aStream: a $ and the character.
     | w | w := WriteStream on: String new. $a printOn: w. w contents >>> '$a'"
    aStream nextPut: $$; nextPut: self ]
Character >> displayOn: aStream [
    "Writes the character itself on aStream, without the $.
     | w | w := WriteStream on: String new. $a displayOn: w. w contents >>> 'a'"
    aStream nextPut: self ]
Character >> shallowCopy [
    "Answers the receiver: an immediate character is its own copy.
     $a shallowCopy >>> $a"
    ^self ]
Character >> deepCopy [
    "Answers the receiver: an immediate character is its own copy.
     $a deepCopy >>> $a"
    ^self ]
Character >> identityHash [
    "Answers the receiver's code point.
     $a identityHash >>> 97"
    ^self value ]
