% kb.pl: a little knowledge base about the planets, and questions over it.
%   ?- planet(P, _, _, Moons), Moons > 10.
%   ?- larger(jupiter, X).
%   ?- setof(P, R^D^M^(planet(P, R, D, M), R > 6000), Big).
%   ?- aggregate_all(sum(M), planet(_, _, _, M), Total).
%   ?- in_order(Ps).

% planet(Name, Radius in km, Distance from the sun in million km, Moons)
planet(mercury,  2440,   58,   0).
planet(venus,    6052,  108,   0).
planet(earth,    6371,  150,   1).
planet(mars,     3390,  228,   2).
planet(jupiter, 69911,  778,  95).
planet(saturn,  58232, 1434, 146).
planet(uranus,  25362, 2871,  28).
planet(neptune, 24622, 4495,  16).

larger(A, B) :- planet(A, RA, _, _), planet(B, RB, _, _), RA > RB.

inner(P) :- planet(P, _, D, _), D < 300.
outer(P) :- planet(P, _, D, _), D >= 300.

% the planets in order from the sun
in_order(Ps) :- findall(D-P, planet(P, _, D, _), L), keysort(L, S), pairs_values(S, Ps).
pairs_values([], []).
pairs_values([_-V|T], [V|Vs]) :- pairs_values(T, Vs).
