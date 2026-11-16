OSServer opCount
(ProcServer default info fields at: 'cores')
(Proc ps detect: [:p | p pid = 1]) name
(Proc ps detect: [:p | p name = 'stratalk']) notNil
Fs statfs first
(Fs tags detect: [:t | t key = 'bin']) value > 40
Dev devices size > 5
(Blk block: 0) size
| t | t := Db tree: 'stalk/test'. t at: 'greeting' put: 'hello'. t at: 'answer' put: '42'. t at: 'greeting'
| t | t := Db tree: 'stalk/test'. (t at: 'nothing' ifAbsent: ['none'])
| t out | t := Db tree: 'stalk/test'. out := OrderedCollection new. t keysAndValuesDo: [:k :v | out add: k -> v]. out
| t | t := Db tree: 'stalk/test'. t removeKey: 'answer'. t at: 'answer' ifAbsent: ['gone']
(FsServer default stat: (Dictionary new at: 'the path' put: '/doc/motd'; at: 'length' put: 9; yourself)) result > 1000
ProcServer default ps result > 5
(File named: 'stalk.txt') write: 'line one'; append: ' and two'. (File named: 'stalk.txt') contents
(File named: 'stalk.txt') delete. File exists: 'stalk.txt'
