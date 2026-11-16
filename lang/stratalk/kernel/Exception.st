"Exception.st: exceptions as in ANSI Smalltalk. A handler runs on top of
 the stack that signalled; returning from it unwinds to the on:do:."

Object subclass: #Exception slots: 'messageText signalFrame handlerFrame'.
"Something signalled for a handler to deal with. signal looks for the
 nearest on:do: whose class handles it and runs its handler on top of the
 stack that signalled; the handler's value is the on:do:'s, unless it
 resumes, retries, returns or passes. With no handler, defaultAction
 decides: here, signal answers nil. messageText is the text (by default
 the class name), signalFrame the frame of signal, handlerFrame the frame
 of the on:do: whose handler runs.
 [Exception signal: 'x'. 5] on: Exception do: [:e | e messageText] >>> 'x'"

Exception subclass: #Error slots: ''.
"An exception for a failure: not resumable, and unhandled it ends the
 expression (Stratalk unhandled: prints 'Error: ' and the text, then goes
 back to the REPL or ends the program). error: signals one.
 [3 error: 'no'] on: Error do: [:e | e messageText] >>> 'no'"

Error subclass: #ZeroDivide slots: ''.
"Signalled by the integer divisions (/, //, \\, rem:, quo: and the like)
 when the divisor is 0. Resumable: resume: makes the division answer its
 argument.
 [(1/0) + 1] on: ZeroDivide do: [:e | e resume: 4] >>> 5"

Error subclass: #MessageNotUnderstood slots: 'message receiver'.
"Signalled by doesNotUnderstand:, which the VM sends when a message has no
 method. message is the Message, receiver the object that did not
 understand it. Resumable: resume: makes the failed send answer its
 argument.
 [nil foo] on: MessageNotUnderstood do: [:e | e messageText] >>> 'nil does not understand #foo'"

Error subclass: #SubscriptOutOfBounds slots: ''.
"Signalled when an index is outside a collection: by indexError:, when an
 indexing primitive fails on an integer index.
 [#(1 2) at: 3] on: SubscriptOutOfBounds do: [:e | e messageText] >>> 'index 3 is out of bounds'"

Error subclass: #NotFound slots: ''.
"Signalled when something looked for is not there: detect: with no match,
 remove: of an absent element.
 [#(1 2) detect: [:x | x > 5]] on: NotFound do: [:e | e messageText] >>> 'nothing was found'"

NotFound subclass: #KeyNotFound slots: ''.
"Signalled by a Dictionary's at: and removeKey: for an absent key, and by
 a MethodDictionary's at: for an absent selector.
 [Dictionary new at: #k] on: KeyNotFound do: [:e | e messageText] >>> 'key not found: #k'"

Error subclass: #BlockCannotReturn slots: ''.
"Signalled by cannotReturn:, which the VM sends for a ^ in a block whose
 home method has returned already."

Error subclass: #NonBooleanReceiver slots: ''.
"Signalled by mustBeBoolean, which the VM sends when the condition of an
 in-line ifTrue:, whileTrue:, and: (and the like) is not a Boolean.
 Resumable.
 [3 ifTrue: [4]] on: NonBooleanReceiver do: [:e | e messageText] >>> '3 is not a Boolean'"

Error subclass: #StackOverflow slots: ''.
"Signalled by Stratalk stackOverflow, which the VM sends when a send would
 overflow the Smalltalk stack (unbounded recursion)."

Error subclass: #AssertionFailure slots: ''.
"Signalled by assert: when its condition is false.
 [3 assert: [1 > 2]] on: AssertionFailure do: [:e | e messageText] >>> 'assertion failed'"

Error subclass: #CompileError slots: 'line'.
"Signalled by the Compiler for source it cannot compile; line is the line
 of the source where it found the error, and messageText begins with it.
 [Compiler evaluate: '3 +'] on: CompileError do: [:e | e messageText] >>> 'line 1: expression expected'"

Error subclass: #FileError slots: ''.
"Signalled by File when a file cannot be opened."

Exception subclass: #Halt slots: ''.
"Signalled by halt. Unhandled, it stops the expression as an Error does.
 [3 halt] on: Halt do: [:e | e class] >>> Halt"

Exception subclass: #Warning slots: ''.
"An exception for something that may be wrong but need not stop the
 program. Unhandled, it writes 'Warning: ' and its text to the Transcript
 and signal answers nil.
 [(Warning signal: 'w') + 1] on: Warning do: [:e | e resume: 4] >>> 5"

Exception subclass: #Notification slots: ''.
"An exception that tells handlers something; unhandled, signal answers
 nil and nothing is shown.
 Notification signal >>> nil"

Object subclass: #ExceptionSet slots: 'classes'.
"Several exception classes as one, for on:do:: made by , between classes.
 It handles an exception that one of its classes handles; classes is an
 OrderedCollection of them.
 [nil foo] on: ZeroDivide, MessageNotUnderstood do: [:e | e class] >>> MessageNotUnderstood"

Exception class >> new [
    "Answers a new exception, without initialize.
     Error new messageText >>> 'Error'"
    ^self basicNew ]
Exception class >> signal [
    "Signals a new instance and answers what signal answers.
     [Error signal] on: Error do: [:e | e messageText] >>> 'Error'"
    ^self new signal ]
Exception class >> signal: aString [
    "Signals a new instance with aString as its messageText.
     [Error signal: 'boom'] on: Error do: [:e | e messageText] >>> 'boom'"
    ^self new signal: aString ]
Exception class >> handles: anException [
    "Answers whether a handler for this class takes anException: whether it
     is an instance of this class or of a subclass.
     Error handles: ZeroDivide new >>> true"
    ^anException isKindOf: self ]
Exception class >> , anExceptionClass [
    "Answers an ExceptionSet of this class and anExceptionClass, for one
     handler of both.
     [1/0] on: ZeroDivide, MessageNotUnderstood do: [:e | e class] >>> ZeroDivide"
    ^ExceptionSet new add: self; add: anExceptionClass; yourself ]
ExceptionSet >> add: aClass [
    "Adds the exception class aClass to the set and answers the set."
    classes == nil ifTrue: [classes := OrderedCollection new]. classes add: aClass ]
ExceptionSet >> , aClass [
    "Adds aClass to the set and answers the set, for a chain of ,.
     [nil foo] on: ZeroDivide, NotFound, MessageNotUnderstood do: [:e | 1] >>> 1"
    self add: aClass ]
ExceptionSet >> handles: anException [
    "Answers whether one of the set's classes handles anException.
     (ZeroDivide, NotFound) handles: KeyNotFound new >>> true"
    ^classes anySatisfy: [:c | c handles: anException] ]

Exception >> messageText [
    "The text of the exception: the one it was signalled with, or else its
     description.
     ZeroDivide new messageText >>> 'ZeroDivide'"
    ^messageText ifNil: [self description] ]
Exception >> messageText: aString [
    "Sets the text of the exception.
     (Error new messageText: 'x'; yourself) messageText >>> 'x'"
    messageText := aString ]
Exception >> description [
    "Answers the default text of the exception: its class name, as a String.
     Error new description >>> 'Error'"
    ^self class name asString ]
Exception >> isResumable [
    "Answers whether a handler may resume the exception: true here, false for
     an Error (except those that say otherwise).
     Warning new isResumable >>> true"
    ^true ]
Exception >> signalFrame [
    "The frame of the signal that raised the exception (a SmallInteger, see
     Frame); nil before it is signalled."
    ^signalFrame ]
Exception >> signal: aString [
    "Sets the text to aString, then signals the exception.
     [ZeroDivide new signal: 'x'] on: ZeroDivide do: [:e | e messageText] >>> 'x'"
    messageText := aString. ^self signal ]
Exception >> signal [
    "Raises the exception: runs the handler of the nearest on:do: that
     handles it, from the sender up, or else defaultAction. Answers the value
     the exception is resumed with (a handler's resume:, or defaultAction's
     answer); a handler that returns does not come back here.
     [ZeroDivide new signal] on: ZeroDivide do: [:e | 3] >>> 3"
    "Look for a handler from the sender of this method up."
    signalFrame := Frame current.
    ^self searchFrom: (Frame sender: signalFrame) ]
Exception >> searchFrom: aFrame [
    "Looks for an on:do: frame from aFrame up whose class handles the
     exception and whose handler is not running already, and handles the
     exception there; with none, answers defaultAction's value."
    | f fl |
    f := aFrame.
    [f = 0] whileFalse: [
        fl := Frame flags: f.
        ((fl bitAnd: 20) = 4 and: [(Frame arg: 1 of: f) handles: self]) ifTrue: [^self handleIn: f].
        f := Frame sender: f].
    ^self defaultAction ]
Exception >> handleIn: aFrame [
    "Runs the handler block of the on:do: frame aFrame, given the exception,
     on top of the stack; the frame is marked (flag 16) so that its handler
     does not take what the handler block signals. If the block ends, its
     value is returned from the on:do: (return:)."
    | result |
    handlerFrame := aFrame.
    Frame flags: ((Frame flags: aFrame) bitOr: 16) of: aFrame.
    result := (Frame arg: 2 of: aFrame) cull: self.
    ^self return: result ]
Exception >> return: anObject [
    "Makes the handler's on:do: answer anObject: runs the unwind blocks
     between, then returns from it. For a handler.
     [Error signal. 5] on: Error do: [:e | e return: 7] >>> 7"
    "Leave the handler's on:do:, which answers anObject."
    | f |
    f := handlerFrame.
    Frame unwindTo: f from: (Frame sender: Frame current).
    Frame return: anObject to: f ]
Exception >> return [
    "Makes the handler's on:do: answer nil.
     [Error signal. 5] on: Error do: [:e | e return] >>> nil"
    ^self return: nil ]
Exception >> retry [
    "Runs the receiver block of the handler's on:do: again, with the same
     handler: unwinds to it, then restarts it. For a handler.
     | n | n := 0. [n := n + 1. n < 3 ifTrue: [Error signal]. n] on: Error do: [:e | e retry] >>> 3"
    | f |
    f := handlerFrame.
    Frame unwindTo: f from: (Frame sender: Frame current).
    Frame restart: f ]
Exception >> resume: anObject [
    "Goes on after the signal, which answers anObject; the handler's on:do:
     can handle again. For a handler; a non-resumable exception (an Error)
     signals an Error instead.
     [(Warning signal: 'w') + 1] on: Warning do: [:e | e resume: 4] >>> 5"
    "Go on after the signal, which answers anObject."
    self isResumable ifFalse: [^IllegalResumeAttempt signal: 'this exception cannot be resumed'].
    handlerFrame == nil ifFalse: [
        Frame flags: ((Frame flags: handlerFrame) bitAnd: 16r7FFFFFEF) of: handlerFrame].
    Frame unwindTo: signalFrame from: (Frame sender: Frame current).
    Frame return: anObject to: signalFrame ]
Exception >> resume [
    "Goes on after the signal, which answers nil.
     [Warning signal] on: Warning do: [:e | e resume] >>> nil"
    ^self resume: nil ]
Exception >> pass [
    "Hands the exception to the next handler out, as if this handler were not
     there; if that one (or defaultAction) resumes with a value, the signal
     here is resumed with it.
     [[1/0] on: ZeroDivide do: [:e | e pass]] on: ZeroDivide do: [:e | 9] >>> 9"
    "As if the handler were not there."
    | outer |
    outer := self searchFrom: (Frame sender: handlerFrame).
    ^self resume: outer ]
Exception >> outer [
    "Hands the exception to the next handler out, as pass does; but if that
     one resumes it (resumable exceptions), outer answers the value, here in
     this handler, rather than the signal.
     [[Warning signal. 1] on: Warning do: [:e | e outer + 10]] on: Warning do: [:e | e resume: 5] >>> 15"
    | savedSignal savedHandler |
    self isResumable ifFalse: [^self pass].
    savedSignal := signalFrame. savedHandler := handlerFrame.
    ^[signalFrame := Frame current.
      self searchFrom: (Frame sender: savedHandler)]
        ensure: [signalFrame := savedSignal. handlerFrame := savedHandler] ]
Exception >> signalerContext [
    "The frame of the signal, as signalFrame (there are no context objects)."
    ^signalFrame ]
Exception >> retryUsing: aBlock [
    "Unwinds to the handler's on:do:, then makes it answer aBlock's value,
     aBlock running in place of its receiver block: with the same handler
     around it.
     [1/0] on: ZeroDivide do: [:e | e retryUsing: [7]] >>> 7"
    | f v |
    f := handlerFrame.
    Frame unwindTo: f from: (Frame sender: Frame current).
    v := aBlock on: (Frame arg: 1 of: f) do: (Frame arg: 2 of: f).
    Frame return: v to: f ]
Exception >> defaultAction [
    "What happens when no handler takes the exception; its value is what
     signal answers. Here nothing: nil.
     Exception signal >>> nil"
    ^nil ]
Exception >> printOn: aStream [
    "Writes the class name, ': ' and the messageText on aStream.
     (Error new messageText: 'oops'; yourself) printString >>> 'Error: oops'"
    aStream nextPutAll: self class name; nextPutAll: ': '; nextPutAll: self messageText ]
Exception >> printBacktraceOn: aStream [
    "Writes on aStream the frames from the sender of signal down, one line
     each, as the REPL shows them for an unhandled error."
    "From the frame that sent signal."
    Frame printBacktraceFrom: (Frame sender: signalFrame) on: aStream ]

Error >> isResumable [
    "Answers false: an Error cannot be resumed (ZeroDivide,
     MessageNotUnderstood and NonBooleanReceiver can).
     Error new isResumable >>> false"
    ^false ]
Error >> defaultAction [
    "Hands the unhandled error to Stratalk unhandled:, which prints it and
     goes back to the REPL, or ends a program with the exit code 1."
    ^Stratalk unhandled: self ]
Object subclass: #IllegalResumeAttempt slots: ''.
"Not an exception class: resume: of a non-resumable exception sends
 IllegalResumeAttempt signal:, which signals a plain Error.
 [[Error signal] on: Error do: [:e | e resume: 1]] on: Error do: [:e | e messageText] >>> 'this exception cannot be resumed'"

IllegalResumeAttempt class >> signal: aString [
    "Signals an Error with aString as its text.
     [IllegalResumeAttempt signal: 'x'] on: Error do: [:e | e messageText] >>> 'x'"
    ^Error new signal: aString ]
Halt >> defaultAction [
    "Hands the unhandled halt to Stratalk unhandled:, as an Error."
    ^Stratalk unhandled: self ]
Warning >> defaultAction [
    "Writes 'Warning: ' and the text on the Transcript and answers nil, which
     the signal answers."
    Transcript showln: 'Warning: ', self messageText.
    ^nil ]

MessageNotUnderstood >> message: aMessage receiver: anObject [
    "Sets the Message that was not understood and the object it was sent to."
    message := aMessage. receiver := anObject ]
MessageNotUnderstood >> message [
    "The Message that was not understood.
     [3 foo: 4] on: MessageNotUnderstood do: [:e | e message selector] >>> #foo:"
    ^message ]
MessageNotUnderstood >> receiver [
    "The object that did not understand the message.
     [3 foo] on: MessageNotUnderstood do: [:e | e receiver] >>> 3"
    ^receiver ]
MessageNotUnderstood >> isResumable [
    "Answers true: resume: makes the failed send answer a value.
     [(nil foo) + 1] on: MessageNotUnderstood do: [:e | e resume: 3] >>> 4"
    ^true ]
MessageNotUnderstood >> messageText [
    "The text given at signal, or else the receiver's printString and the
     selector it does not understand.
     [3 foo] on: MessageNotUnderstood do: [:e | e messageText] >>> '3 does not understand #foo'"
    ^messageText ifNil: [receiver printString, ' does not understand #', message selector] ]
ZeroDivide >> isResumable [
    "Answers true: resume: makes the division answer a value.
     [(1/0) + 1] on: ZeroDivide do: [:e | e resume: 4] >>> 5"
    ^true ]
NonBooleanReceiver >> isResumable [
    "Answers true.
     NonBooleanReceiver new isResumable >>> true"
    ^true ]
CompileError >> line [
    "The source line of the error.
     [Compiler evaluate: '3 +'] on: CompileError do: [:e | e line] >>> 1"
    ^line ]
CompileError >> line: n [
    "Sets the source line of the error."
    line := n ]
