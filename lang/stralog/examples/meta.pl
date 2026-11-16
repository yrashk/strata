% meta.pl: Prolog in Prolog. solve/1 runs a goal by clause/2, the "vanilla"
% meta-interpreter; proof/2 also gives the proof tree.
%   ?- solve(app(X, Y, [1, 2])).
%   ?- proof(app([1], [2], L), P).

:- dynamic(app/3).
app([], L, L).
app([H|T], L, [H|R]) :- app(T, L, R).

solve(true) :- !.
solve((A, B)) :- !, solve(A), solve(B).
solve(G) :- user_pred(G), !, clause(G, Body), solve(Body).
solve(G) :- call(G).

proof(true, true) :- !.
proof((A, B), (PA, PB)) :- !, proof(A, PA), proof(B, PB).
proof(G, G-builtin) :- \+ user_pred(G), !, call(G).
proof(G, G-P) :- clause(G, Body), proof(Body, P).

user_pred(G) :- functor(G, N, A), current_predicate(N/A).
