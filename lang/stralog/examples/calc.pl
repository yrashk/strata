% calc.pl: a calculator written as a DCG: it parses the text of an
% expression into a tree and evaluates it.
%   ?- calc("2 * (3 + 4) - 5", V).
%   ?- parse("1 + 2 * 3", T).

calc(Text, V) :- parse(Text, T), V is T.

parse(Text, T) :- phrase(expr(T), Text).

expr(T)   --> blanks, term(T0), expr_rest(T0, T), blanks.
expr_rest(T0, T) --> blanks, "+", !, blanks, term(T1), expr_rest(T0 + T1, T).
expr_rest(T0, T) --> blanks, "-", !, blanks, term(T1), expr_rest(T0 - T1, T).
expr_rest(T, T)  --> [].

term(T)   --> factor(T0), term_rest(T0, T).
term_rest(T0, T) --> blanks, "*", !, blanks, factor(T1), term_rest(T0 * T1, T).
term_rest(T0, T) --> blanks, "/", !, blanks, factor(T1), term_rest(T0 // T1, T).
term_rest(T, T)  --> [].

factor(T) --> "(", !, expr(T), ")".
factor(N) --> digits(Ds), { Ds \== [], number_codes(N, Ds) }.

digits([D|Ds]) --> [D], { D >= 0'0, D =< 0'9 }, !, digits(Ds).
digits([])     --> [].

blanks --> " ", !, blanks.
blanks --> [].
