% queens.pl: N queens on an N x N board, none attacking another.
%   ?- queens2(8, Qs), show(Qs).   the first solution, drawn
%   ?- count_queens(6, N).         how many there are
%   ?- queens(6, Qs).              by generate and test: slower
% Qs lists, column by column, the row of each column's queen.

queens(N, Qs) :-
    numlist(1, N, Ns),
    permutation(Ns, Qs),
    safe(Qs).

safe([]).
safe([Q|Qs]) :- no_attack(Q, Qs, 1), safe(Qs).

no_attack(_, [], _).
no_attack(Q, [Q1|Qs], D) :-
    Q =\= Q1 + D,
    Q =\= Q1 - D,
    D1 is D + 1,
    no_attack(Q, Qs, D1).

% faster: place queens column by column, checking as it goes
queens2(N, Qs) :- numlist(1, N, Ns), place(Ns, [], Qs).

place([], Qs, Qs).
place(Unplaced, Safe, Qs) :-
    select(Q, Unplaced, Rest),
    no_attack(Q, Safe, 1),
    place(Rest, [Q|Safe], Qs).

count_queens(N, C) :- findall(Q, queens2(N, Q), L), length(L, C).

% the board, drawn
show(Qs) :- length(Qs, N), show_rows(Qs, N).
show_rows([], _).
show_rows([Q|Qs], N) :- show_row(1, N, Q), nl, show_rows(Qs, N).
show_row(I, N, _) :- I > N, !.
show_row(I, N, Q) :- ( I =:= Q -> write(' Q') ; write(' .') ), I1 is I + 1, show_row(I1, N, Q).
