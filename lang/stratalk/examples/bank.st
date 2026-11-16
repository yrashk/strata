"bank.st: a small domain model with its own errors."

Error subclass: #InsufficientFunds slots: ''.
Object subclass: #Account slots: 'owner balance history'.

Account class >> owner: aString [ ^self new setOwner: aString ]
Account >> setOwner: aString [ owner := aString. balance := 0. history := OrderedCollection new ]
Account >> balance [ ^balance ]
Account >> deposit: n [ n > 0 ifFalse: [^self error: 'deposits are positive']. balance := balance + n. history add: n ]
Account >> withdraw: n [
    n > balance ifTrue: [^InsufficientFunds new signal: owner, ' has only ', balance printString].
    balance := balance - n. history add: n negated ]
Account >> history [ ^history ]

| acct |
acct := Account owner: 'Ada'.
acct deposit: 100; deposit: 50; withdraw: 30.
[acct withdraw: 500] on: InsufficientFunds do: [:e | Transcript showln: 'refused: ', e messageText].
Transcript showln: 'balance: ', acct balance printString, ' history: ', acct history asArray printString.
