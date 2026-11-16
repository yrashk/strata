"shapes.st: classes, inheritance, polymorphism, super."

Object subclass: #Shape slots: 'name'.
Shape subclass: #Circle slots: 'radius'.
Shape subclass: #Rect slots: 'width height'.
Rect subclass: #Square slots: ''.

Shape >> name [ ^name ifNil: [self class name] ]
Shape >> area [ ^self subclassResponsibility ]
Shape >> describe [ ^self name, ' with area ', self area printString ]

Circle class >> radius: r [ ^self new setRadius: r ]
Circle >> setRadius: r [ radius := r ]
Circle >> area [ "pi as 355/113, in integers" ^radius * radius * 355 // 113 ]

Rect class >> width: w height: h [ ^self new setWidth: w height: h ]
Rect >> setWidth: w height: h [ width := w. height := h ]
Rect >> area [ ^width * height ]

Square class >> side: s [ ^self width: s height: s ]
Square >> describe [ ^'a square! ', super describe ]

| shapes |
shapes := {Circle radius: 10. Rect width: 3 height: 4. Square side: 5}.
shapes do: [:s | Transcript showln: s describe].
Transcript showln: 'total area: ', (shapes inject: 0 into: [:sum :s | sum + s area]) printString.
Transcript showln: 'largest: ', (shapes inject: shapes first into: [:m :s | s area > m area ifTrue: [s] ifFalse: [m]]) name.
