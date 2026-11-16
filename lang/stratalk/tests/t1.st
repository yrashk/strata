(3 + 4) printNl.
(100 factorial) printNl.
#(1 $a 'str' #sym (1 2)) printNl.
((1 to: 10) inject: 0 into: [:a :b | a + b]) printNl.
((1 to: 10) select: [:x | x even]) printNl.
(OrderedCollection new add: 3; add: 4; yourself) printNl.
| d | d := Dictionary new. d at: #a put: 1. d at: #b put: 2. d printNl.
'hello' reversed printNl.
[:x | x * 2] printNl.
([10 / 0] on: ZeroDivide do: [:e | e messageText]) printNl.
([nil foo] on: MessageNotUnderstood do: [:e | e return: 5]) printNl.
| r | r := OrderedCollection new. [r add: 1] ensure: [r add: 2]. r printNl.
(3 @ 4 + 1) printNl.
#(3 1 2) asSortedCollection printNl.
('a:b:c' substrings: ':') printNl.
(2 raisedTo: 100) printNl.
((2 raisedTo: 100) // 3) printNl.
1000000000000 * 1000000000000 printNl.
(1000000000000 * 1000000000000) printNl.
