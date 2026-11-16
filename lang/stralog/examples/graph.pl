% graph.pl: paths in a directed graph, without going round in circles, and
% the shortest one by breadth-first search.
%   ?- path(a, e, P).
%   ?- shortest(a, e, P).
%   ?- reachable(a, L).

edge(a, b). edge(a, c). edge(b, d). edge(c, d).
edge(d, e). edge(b, e). edge(e, a). edge(c, f).

path(X, Y, P) :- path(X, Y, [X], Q), reverse(Q, P).
path(X, X, Seen, Seen).
path(X, Y, Seen, P) :- edge(X, Z), \+ memberchk(Z, Seen), path(Z, Y, [Z|Seen], P).

shortest(X, Y, P) :- bfs([[X]], Y, Q), reverse(Q, P).
bfs([[Y|T]|_], Y, [Y|T]) :- !.
bfs([[N|T]|Rest], Y, P) :-
    findall([M, N|T], (edge(N, M), \+ memberchk(M, [N|T])), Next),
    append(Rest, Next, Queue),
    bfs(Queue, Y, P).

reachable(X, L) :- setof(Y, P^path(X, Y, P), L).
