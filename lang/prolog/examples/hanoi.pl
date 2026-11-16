% hanoi.pl: the towers of Hanoi.
%   ?- hanoi(3).                 prints the moves
%   ?- moves(10, N).             how many moves for 10 discs

hanoi(N) :- move(N, left, right, middle).

move(0, _, _, _) :- !.
move(N, From, To, Via) :-
    M is N - 1,
    move(M, From, Via, To),
    format('move a disc from ~w to ~w~n', [From, To]),
    move(M, Via, To, From).

moves(0, 0) :- !.
moves(N, M) :- N1 is N - 1, moves(N1, M1), M is 2 * M1 + 1.
