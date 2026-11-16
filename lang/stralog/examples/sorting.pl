% sorting.pl: two sorts of a list of numbers, and a benchmark.
%   ?- qsort([3,1,4,1,5,9,2,6], L).
%   ?- isort([3,1,2], L).
%   ?- nrev_bench(300).          naive reverse of 300 elements, with statistics

qsort([], []).
qsort([P|Xs], S) :-
    partition(Xs, P, Small, Big),
    qsort(Small, S1), qsort(Big, S2),
    append(S1, [P|S2], S).

partition([], _, [], []).
partition([X|Xs], P, [X|S], B) :- X =< P, !, partition(Xs, P, S, B).
partition([X|Xs], P, S, [X|B]) :- partition(Xs, P, S, B).

isort([], []).
isort([X|Xs], S) :- isort(Xs, S0), insert(X, S0, S).
insert(X, [Y|Ys], [Y|Zs]) :- Y < X, !, insert(X, Ys, Zs).
insert(X, Ys, [X|Ys]).

nrev([], []).
nrev([H|T], R) :- nrev(T, RT), append(RT, [H], R).

nrev_bench(N) :- numlist(1, N, L), nrev(L, R), R = [First|_],
    format('reversed ~d elements, first now ~d~n', [N, First]), statistics.
