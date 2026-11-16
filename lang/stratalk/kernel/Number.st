"Number.st: magnitudes, integers (small and large), characters."

Object subclass: #Magnitude slots: ''.
Magnitude subclass: #Character slots: ''.
Magnitude subclass: #Number slots: ''.
Number subclass: #Integer slots: ''.
Integer subclass: #SmallInteger slots: ''.
Integer byteSubclass: #LargePositiveInteger slots: ''.
LargePositiveInteger subclass: #LargeNegativeInteger slots: ''.

"---- Magnitude ----------------------------------------------------------------"

Magnitude >> < aMagnitude [ ^self subclassResponsibility ]
Magnitude >> > aMagnitude [ ^aMagnitude < self ]
Magnitude >> <= aMagnitude [ ^(aMagnitude < self) not ]
Magnitude >> >= aMagnitude [ ^(self < aMagnitude) not ]
Magnitude >> between: min and: max [ ^self >= min and: [self <= max] ]
Magnitude >> min: aMagnitude [ ^self < aMagnitude ifTrue: [self] ifFalse: [aMagnitude] ]
Magnitude >> max: aMagnitude [ ^self > aMagnitude ifTrue: [self] ifFalse: [aMagnitude] ]

"---- Number ---------------------------------------------------------------------"

Number >> isNumber [ ^true ]
Number >> isZero [ ^self = 0 ]
Number >> negative [ ^self < 0 ]
Number >> positive [ ^self >= 0 ]
Number >> strictlyPositive [ ^self > 0 ]
Number >> sign [ self > 0 ifTrue: [^1]. self < 0 ifTrue: [^-1]. ^0 ]
Number >> negated [ ^0 - self ]
Number >> abs [ ^self < 0 ifTrue: [self negated] ifFalse: [self] ]
Number >> squared [ ^self * self ]
Number >> even [ ^(self \\ 2) = 0 ]
Number >> odd [ ^(self \\ 2) = 1 ]
Number >> to: stop [ ^Interval from: self to: stop by: 1 ]
Number >> to: stop by: step [ ^Interval from: self to: stop by: step ]
Number >> to: stop do: aBlock [
    | i |
    i := self.
    [i <= stop] whileTrue: [aBlock value: i. i := i + 1] ]
Number >> to: stop by: step do: aBlock [
    | i |
    i := self.
    step > 0
        ifTrue: [[i <= stop] whileTrue: [aBlock value: i. i := i + step]]
        ifFalse: [[i >= stop] whileTrue: [aBlock value: i. i := i + step]] ]
Number >> timesRepeat: aBlock [
    | i |
    i := 1.
    [i <= self] whileTrue: [aBlock value. i := i + 1] ]
Number >> @ y [ ^Point x: self y: y ]
Number >> printOn: aStream [ aStream nextPutAll: (self printString: 10) ]
Number >> printString [ ^self printString: 10 ]
Number >> displayString [ ^self printString ]

"---- Integer -------------------------------------------------------------------"

Integer >> isInteger [ ^true ]
Integer >> factorial [
    | r |
    self < 0 ifTrue: [^self error: 'factorial of a negative number'].
    r := 1.
    2 to: self do: [:i | r := r * i].
    ^r ]
Integer >> gcd: anInteger [
    | a b t |
    a := self abs. b := anInteger abs.
    [b = 0] whileFalse: [t := a \\ b. a := b. b := t].
    ^a ]
Integer >> lcm: anInteger [ ^(self * anInteger) abs // (self gcd: anInteger) ]
Integer >> isPrime [
    | i |
    self < 2 ifTrue: [^false].
    i := 2.
    [i * i <= self] whileTrue: [(self \\ i) = 0 ifTrue: [^false]. i := i + 1].
    ^true ]
Integer >> fib [ self < 2 ifTrue: [^self]. ^(self - 1) fib + (self - 2) fib ]
Integer >> sqrtFloor [
    | x y |
    self < 0 ifTrue: [^self error: 'square root of a negative number'].
    self < 2 ifTrue: [^self].
    x := self. y := (x + 1) // 2.
    [y < x] whileTrue: [x := y. y := (x + (self // x)) // 2].
    ^x ]
Integer >> raisedTo: n [
    | r b e |
    n < 0 ifTrue: [^self error: 'negative exponent'].
    r := 1. b := self. e := n.
    [e > 0] whileTrue: [
        (e bitAnd: 1) = 1 ifTrue: [r := r * b].
        e := e bitShift: -1.
        e > 0 ifTrue: [b := b * b]].
    ^r ]
Integer >> asCharacter [ ^Character value: self ]
Integer >> asInteger [ ^self ]
Integer >> printString: base [
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
    | s |
    s := self printString: base.
    ^(String new: (n - s size max: 0) withAll: $0), s ]
Integer >> hex [ ^self printString: 16 ]
Integer >> isLarge [ ^false ]

"---- SmallInteger: the VM does these, and fails to a slower path ----------"

SmallInteger >> + n [ <primitive: 1> ^self largeOp: #+ with: n ]
SmallInteger >> - n [ <primitive: 2> ^self largeOp: #- with: n ]
SmallInteger >> < n [ <primitive: 3> ^self largeCompare: #< with: n ]
SmallInteger >> > n [ <primitive: 4> ^self largeCompare: #> with: n ]
SmallInteger >> <= n [ <primitive: 5> ^self largeCompare: #<= with: n ]
SmallInteger >> >= n [ <primitive: 6> ^self largeCompare: #>= with: n ]
SmallInteger >> = n [ <primitive: 7> ^n isNumber and: [self largeCompare: #= with: n] ]
SmallInteger >> ~= n [ <primitive: 8> ^(self = n) not ]
SmallInteger >> * n [ <primitive: 9> ^self largeOp: #* with: n ]
SmallInteger >> / n [
    <primitive: 10>
    n = 0 ifTrue: [^ZeroDivide new signal: 'division by zero'].
    (n isInteger and: [(self \\ n) = 0]) ifTrue: [^self // n].
    ^self error: 'fractions are not supported' ]
SmallInteger >> \\ n [
    <primitive: 11>
    n = 0 ifTrue: [^ZeroDivide new signal: 'division by zero'].
    ^self largeOp: #\\ with: n ]
SmallInteger >> // n [
    <primitive: 12>
    n = 0 ifTrue: [^ZeroDivide new signal: 'division by zero'].
    ^self largeOp: #// with: n ]
SmallInteger >> quo: n [
    <primitive: 13>
    n = 0 ifTrue: [^ZeroDivide new signal: 'division by zero'].
    ^self largeOp: #quo: with: n ]
SmallInteger >> rem: n [
    <primitive: 14>
    n = 0 ifTrue: [^ZeroDivide new signal: 'division by zero'].
    ^self largeOp: #rem: with: n ]
SmallInteger >> bitAnd: n [ <primitive: 15> ^self largeOp: #bitAnd: with: n ]
SmallInteger >> bitOr: n [ <primitive: 16> ^self largeOp: #bitOr: with: n ]
SmallInteger >> bitXor: n [ <primitive: 17> ^self largeOp: #bitXor: with: n ]
SmallInteger >> bitShift: n [ <primitive: 18> ^self largeOp: #bitShift: with: n ]
SmallInteger >> printString [ <primitive: 19> ^self printString: 10 ]
SmallInteger >> printOn: aStream [ aStream nextPutAll: self printString ]
SmallInteger >> identityHash [ ^self ]
SmallInteger >> hash [ ^self ]
SmallInteger >> largeOp: aSymbol with: n [
    n isInteger ifFalse: [^self error: 'an integer was expected, not ', n printString].
    ^(LargePositiveInteger fromInteger: self) perform: aSymbol with: n ]
SmallInteger >> largeCompare: aSymbol with: n [
    n isInteger ifFalse: [^self error: 'an integer was expected, not ', n printString].
    ^(LargePositiveInteger fromInteger: self) perform: aSymbol with: n ]
SmallInteger >> shallowCopy [ ^self ]
SmallInteger >> deepCopy [ ^self ]
SmallInteger class >> maxVal [ ^4611686018427387903 ]
SmallInteger class >> minVal [ ^-4611686018427387904 ]

"---- large integers: bytes, least significant first; the sign is the class ----"

LargePositiveInteger class >> fromInteger: n [
    "n as a large integer (a SmallInteger or a large one)."
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
    "The integer of these bytes (least significant first), made small if it fits."
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
LargePositiveInteger >> isLarge [ ^true ]
LargePositiveInteger >> digitAt: i [ <primitive: 44> ^0 ]
LargePositiveInteger >> digitAt: i put: b [ <primitive: 45> ]
LargePositiveInteger >> digitLength [ ^self basicSize ]
LargePositiveInteger >> isNegative [ ^false ]
LargeNegativeInteger >> isNegative [ ^true ]
LargePositiveInteger >> digits [
    | d |
    d := Array new: self digitLength.
    1 to: d size do: [:i | d at: i put: (self digitAt: i)].
    ^d ]
LargePositiveInteger >> negated [
    ^LargePositiveInteger digits: self digits negative: self isNegative not ]
LargePositiveInteger >> abs [ ^LargePositiveInteger digits: self digits negative: false ]
LargePositiveInteger >> < n [ ^(self compare: n) < 0 ]
LargePositiveInteger >> > n [ ^(self compare: n) > 0 ]
LargePositiveInteger >> <= n [ ^(self compare: n) <= 0 ]
LargePositiveInteger >> >= n [ ^(self compare: n) >= 0 ]
LargePositiveInteger >> = n [ ^n isInteger and: [(self compare: n) = 0] ]
LargePositiveInteger >> hash [ ^(self digitAt: 1) + ((self digitAt: 2) * 256) ]
LargePositiveInteger >> compare: n [
    | a b c |
    a := self. b := LargePositiveInteger fromInteger: n.
    a isNegative ~= b isNegative ifTrue: [^a isNegative ifTrue: [-1] ifFalse: [1]].
    c := LargePositiveInteger compareDigits: a digits with: b digits.
    ^a isNegative ifTrue: [0 - c] ifFalse: [c] ]
LargePositiveInteger class >> compareDigits: a with: b [
    | n x y |
    n := a size max: b size.
    n to: 1 by: -1 do: [:i |
        x := i <= a size ifTrue: [a at: i] ifFalse: [0].
        y := i <= b size ifTrue: [b at: i] ifFalse: [0].
        x < y ifTrue: [^-1].
        x > y ifTrue: [^1]].
    ^0 ]
LargePositiveInteger class >> addDigits: a to: b [
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
    "a - b, a >= b"
    | r borrow s |
    r := Array new: a size.
    borrow := 0.
    1 to: a size do: [:i |
        s := (a at: i) - borrow - (i <= b size ifTrue: [b at: i] ifFalse: [0]).
        s < 0 ifTrue: [s := s + 256. borrow := 1] ifFalse: [borrow := 0].
        r at: i put: s].
    ^r ]
LargePositiveInteger class >> multiplyDigits: a by: b [
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
    "a // d and a \\ d for a small d: an Array {quotient digits. remainder}"
    | q r t |
    q := Array new: a size.
    r := 0.
    a size to: 1 by: -1 do: [:i |
        t := (r bitShift: 8) + (a at: i).
        q at: i put: t // d.
        r := t \\ d].
    ^Array with: q with: r ]
LargePositiveInteger >> + n [
    | a b c |
    a := self. b := LargePositiveInteger fromInteger: n.
    a isNegative = b isNegative ifTrue: [
        ^LargePositiveInteger digits: (LargePositiveInteger addDigits: a digits to: b digits) negative: a isNegative].
    c := LargePositiveInteger compareDigits: a digits with: b digits.
    c = 0 ifTrue: [^0].
    c > 0 ifTrue: [^LargePositiveInteger digits: (LargePositiveInteger subtractDigits: b digits from: a digits) negative: a isNegative].
    ^LargePositiveInteger digits: (LargePositiveInteger subtractDigits: a digits from: b digits) negative: b isNegative ]
LargePositiveInteger >> - n [ ^self + (LargePositiveInteger fromInteger: n) negated ]
LargePositiveInteger >> * n [
    | b |
    b := LargePositiveInteger fromInteger: n.
    ^LargePositiveInteger digits: (LargePositiveInteger multiplyDigits: self digits by: b digits)
        negative: self isNegative ~= b isNegative ]
LargePositiveInteger >> divmod: n [
    "{quotient. remainder} of a division rounding toward zero."
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
LargePositiveInteger >> bitAt: i [ ^((self digitAt: (i - 1) // 8 + 1) bitShift: 0 - ((i - 1) \\ 8)) bitAnd: 1 ]
LargePositiveInteger >> quo: n [ ^(self divmod: n) at: 1 ]
LargePositiveInteger >> rem: n [ ^(self divmod: n) at: 2 ]
LargePositiveInteger >> // n [
    | qr |
    qr := self divmod: n.
    ((qr at: 2) ~= 0 and: [self negative ~= n negative]) ifTrue: [^(qr at: 1) - 1].
    ^qr at: 1 ]
LargePositiveInteger >> \\ n [
    | r |
    r := (self divmod: n) at: 2.
    (r ~= 0 and: [r negative ~= n negative]) ifTrue: [^r + n].
    ^r ]
LargePositiveInteger >> / n [
    (self \\ n) = 0 ifTrue: [^self // n].
    ^self error: 'fractions are not supported' ]
LargePositiveInteger >> negative [ ^self isNegative ]
LargePositiveInteger >> bitShift: n [
    n >= 0 ifTrue: [^self * (2 raisedTo: n)].
    ^self // (2 raisedTo: 0 - n) ]
LargePositiveInteger >> bitOp: n with: aBlock [
    "Byte by byte, for integers >= 0."
    | a b r |
    (self negative or: [n negative]) ifTrue: [^self error: 'bitwise operations of negative large integers are not supported'].
    a := self digits. b := (LargePositiveInteger fromInteger: n) digits.
    r := Array new: (a size max: b size).
    1 to: r size do: [:i |
        r at: i put: (aBlock value: (i <= a size ifTrue: [a at: i] ifFalse: [0]) value: (i <= b size ifTrue: [b at: i] ifFalse: [0]))].
    ^LargePositiveInteger digits: r negative: false ]
LargePositiveInteger >> bitAnd: n [ ^self bitOp: n with: [:x :y | x bitAnd: y] ]
LargePositiveInteger >> bitOr: n [ ^self bitOp: n with: [:x :y | x bitOr: y] ]
LargePositiveInteger >> bitXor: n [ ^self bitOp: n with: [:x :y | x bitXor: y] ]
LargePositiveInteger >> printString: base [
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
LargePositiveInteger >> printOn: aStream [ aStream nextPutAll: (self printString: 10) ]
LargePositiveInteger >> printString [ ^self printString: 10 ]
LargePositiveInteger >> shallowCopy [ ^self ]

"---- Character: immediate; the value is a Unicode code point ------------------"

Character class >> value: anInteger [ <primitive: 31> ^self error: 'not a character code' ]
Character class >> digitValue: n [ ^'0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ' at: n + 1 ]
Character class >> cr [ ^Character value: 10 ]
Character class >> lf [ ^Character value: 10 ]
Character class >> tab [ ^Character value: 9 ]
Character class >> space [ ^Character value: 32 ]
Character class >> nul [ ^Character value: 0 ]
Character class >> escape [ ^Character value: 27 ]
Character class >> backspace [ ^Character value: 8 ]
Character >> value [ <primitive: 30> ]
Character >> asInteger [ <primitive: 30> ]
Character >> asCharacter [ ^self ]
Character >> isCharacter [ ^true ]
Character >> = aChar [ ^self == aChar ]
Character >> hash [ ^self value ]
Character >> < aChar [ ^self value < aChar value ]
Character >> > aChar [ ^self value > aChar value ]
Character >> <= aChar [ ^self value <= aChar value ]
Character >> >= aChar [ ^self value >= aChar value ]
Character >> isVowel [ ^'aeiouAEIOU' includes: self ]
Character >> isLetter [ ^self isUppercase or: [self isLowercase] ]
Character >> isUppercase [ ^self value between: 65 and: 90 ]
Character >> isLowercase [ ^self value between: 97 and: 122 ]
Character >> isDigit [ ^self value between: 48 and: 57 ]
Character >> isAlphaNumeric [ ^self isLetter or: [self isDigit] ]
Character >> isSeparator [ ^self value = 32 or: [self value between: 9 and: 13] ]
Character >> isPunctuation [ ^'.,:;!?' includes: self ]
Character >> digitValue [
    self isDigit ifTrue: [^self value - 48].
    self isUppercase ifTrue: [^self value - 55].
    self isLowercase ifTrue: [^self value - 87].
    ^-1 ]
Character >> asUppercase [ ^self isLowercase ifTrue: [Character value: self value - 32] ifFalse: [self] ]
Character >> asLowercase [ ^self isUppercase ifTrue: [Character value: self value + 32] ifFalse: [self] ]
Character >> asString [ ^String with: self ]
Character >> asSymbol [ ^self asString asSymbol ]
Character >> printOn: aStream [ aStream nextPut: $$; nextPut: self ]
Character >> displayOn: aStream [ aStream nextPut: self ]
Character >> shallowCopy [ ^self ]
Character >> deepCopy [ ^self ]
Character >> identityHash [ ^self value ]
