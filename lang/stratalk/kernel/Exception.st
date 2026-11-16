"Exception.st: exceptions as in ANSI Smalltalk. A handler runs on top of
 the stack that signalled; returning from it unwinds to the on:do:."

Object subclass: #Exception slots: 'messageText signalFrame handlerFrame'.
Exception subclass: #Error slots: ''.
Error subclass: #ZeroDivide slots: ''.
Error subclass: #MessageNotUnderstood slots: 'message receiver'.
Error subclass: #SubscriptOutOfBounds slots: ''.
Error subclass: #NotFound slots: ''.
NotFound subclass: #KeyNotFound slots: ''.
Error subclass: #BlockCannotReturn slots: ''.
Error subclass: #NonBooleanReceiver slots: ''.
Error subclass: #StackOverflow slots: ''.
Error subclass: #AssertionFailure slots: ''.
Error subclass: #CompileError slots: 'line'.
Error subclass: #FileError slots: ''.
Exception subclass: #Halt slots: ''.
Exception subclass: #Warning slots: ''.
Exception subclass: #Notification slots: ''.
Object subclass: #ExceptionSet slots: 'classes'.

Exception class >> new [ ^self basicNew ]
Exception class >> signal [ ^self new signal ]
Exception class >> signal: aString [ ^self new signal: aString ]
Exception class >> handles: anException [ ^anException isKindOf: self ]
Exception class >> , anExceptionClass [ ^ExceptionSet new add: self; add: anExceptionClass; yourself ]
ExceptionSet >> add: aClass [ classes == nil ifTrue: [classes := OrderedCollection new]. classes add: aClass ]
ExceptionSet >> , aClass [ self add: aClass ]
ExceptionSet >> handles: anException [ ^classes anySatisfy: [:c | c handles: anException] ]

Exception >> messageText [ ^messageText ifNil: [self description] ]
Exception >> messageText: aString [ messageText := aString ]
Exception >> description [ ^self class name ]
Exception >> isResumable [ ^true ]
Exception >> signalFrame [ ^signalFrame ]
Exception >> signal: aString [ messageText := aString. ^self signal ]
Exception >> signal [
    "Look for a handler from the sender of this method up."
    signalFrame := Frame current.
    ^self searchFrom: (Frame sender: signalFrame) ]
Exception >> searchFrom: aFrame [
    | f fl |
    f := aFrame.
    [f = 0] whileFalse: [
        fl := Frame flags: f.
        ((fl bitAnd: 20) = 4 and: [(Frame arg: 1 of: f) handles: self]) ifTrue: [^self handleIn: f].
        f := Frame sender: f].
    ^self defaultAction ]
Exception >> handleIn: aFrame [
    | result |
    handlerFrame := aFrame.
    Frame flags: ((Frame flags: aFrame) bitOr: 16) of: aFrame.
    result := (Frame arg: 2 of: aFrame) cull: self.
    ^self return: result ]
Exception >> return: anObject [
    "Leave the handler's on:do:, which answers anObject."
    | f |
    f := handlerFrame.
    Frame unwindTo: f from: (Frame sender: Frame current).
    Frame return: anObject to: f ]
Exception >> return [ ^self return: nil ]
Exception >> retry [
    | f |
    f := handlerFrame.
    Frame unwindTo: f from: (Frame sender: Frame current).
    Frame restart: f ]
Exception >> resume: anObject [
    "Go on after the signal, which answers anObject."
    self isResumable ifFalse: [^IllegalResumeAttempt signal: 'this exception cannot be resumed'].
    handlerFrame == nil ifFalse: [
        Frame flags: ((Frame flags: handlerFrame) bitAnd: 16r7FFFFFEF) of: handlerFrame].
    Frame unwindTo: signalFrame from: (Frame sender: Frame current).
    Frame return: anObject to: signalFrame ]
Exception >> resume [ ^self resume: nil ]
Exception >> pass [
    "As if the handler were not there."
    | outer |
    outer := self searchFrom: (Frame sender: handlerFrame).
    ^self resume: outer ]
Exception >> outer [ ^self pass ]
Exception >> signalerContext [ ^signalFrame ]
Exception >> retryUsing: aBlock [
    | f |
    f := handlerFrame.
    Frame unwindTo: f from: (Frame sender: Frame current).
    Frame return: aBlock value to: f ]
Exception >> defaultAction [ ^nil ]
Exception >> printOn: aStream [ aStream nextPutAll: self class name; nextPutAll: ': '; nextPutAll: self messageText ]
Exception >> printBacktraceOn: aStream [
    "From the frame that sent signal."
    Frame printBacktraceFrom: (Frame sender: signalFrame) on: aStream ]

Error >> isResumable [ ^false ]
Error >> defaultAction [ ^Stratalk unhandled: self ]
Object subclass: #IllegalResumeAttempt slots: ''.
IllegalResumeAttempt class >> signal: aString [ ^Error new signal: aString ]
Halt >> defaultAction [ ^Stratalk unhandled: self ]
Warning >> defaultAction [
    Transcript showln: 'Warning: ', self messageText.
    ^nil ]

MessageNotUnderstood >> message: aMessage receiver: anObject [ message := aMessage. receiver := anObject ]
MessageNotUnderstood >> message [ ^message ]
MessageNotUnderstood >> receiver [ ^receiver ]
MessageNotUnderstood >> isResumable [ ^true ]
MessageNotUnderstood >> messageText [
    ^messageText ifNil: [receiver printString, ' does not understand #', message selector] ]
ZeroDivide >> isResumable [ ^true ]
NonBooleanReceiver >> isResumable [ ^true ]
CompileError >> line [ ^line ]
CompileError >> line: n [ line := n ]
