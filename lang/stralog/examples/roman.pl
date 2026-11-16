% roman.pl: Roman numerals, both ways, with a DCG.
%   ?- roman(1987, R).            R = 'MCMLXXXVII'
%   ?- arabic('MMXXVI', N).

roman(N, R) :- integer(N), N > 0, N < 4000, numeral(N, Cs, []), atom_codes(R, Cs).
arabic(R, N) :- atom_codes(R, Cs), between(1, 3999, N), numeral(N, Cs, []), !.

numeral(N) --> { N >= 1000, !, N1 is N - 1000 }, "M", numeral(N1).
numeral(N) --> { N >= 900, !, N1 is N - 900 }, "CM", numeral(N1).
numeral(N) --> { N >= 500, !, N1 is N - 500 }, "D", numeral(N1).
numeral(N) --> { N >= 400, !, N1 is N - 400 }, "CD", numeral(N1).
numeral(N) --> { N >= 100, !, N1 is N - 100 }, "C", numeral(N1).
numeral(N) --> { N >= 90, !, N1 is N - 90 }, "XC", numeral(N1).
numeral(N) --> { N >= 50, !, N1 is N - 50 }, "L", numeral(N1).
numeral(N) --> { N >= 40, !, N1 is N - 40 }, "XL", numeral(N1).
numeral(N) --> { N >= 10, !, N1 is N - 10 }, "X", numeral(N1).
numeral(N) --> { N >= 9, !, N1 is N - 9 }, "IX", numeral(N1).
numeral(N) --> { N >= 5, !, N1 is N - 5 }, "V", numeral(N1).
numeral(N) --> { N >= 4, !, N1 is N - 4 }, "IV", numeral(N1).
numeral(N) --> { N >= 1, !, N1 is N - 1 }, "I", numeral(N1).
numeral(0) --> [].
