"queens.st: the eight queens, with blocks that call themselves."

| solve count first |
count := 0.
solve := nil.
solve := [:row :cols |
    row > 8
        ifTrue: [count := count + 1. first ifNil: [first := cols copy]]
        ifFalse: [
            1 to: 8 do: [:c |
                ((1 to: row - 1) allSatisfy: [:r |
                    | d | d := cols at: r.
                    d ~= c and: [(d - c) abs ~= (row - r)]])
                    ifTrue: [cols at: row put: c. solve value: row + 1 value: cols]]]].
solve value: 1 value: (Array new: 8).
Transcript showln: count printString, ' solutions; the first: ', first printString.
