% zebra.pl: the zebra puzzle. Five houses in a row, each of one colour, its
% owner of one nationality, with one pet, one drink and one smoke.
%   ?- zebra(Owner).            who owns the zebra?
%   ?- houses(Hs).              the whole street

houses(Hs) :-
    length(Hs, 5),
    member(h(red, english, _, _, _), Hs),
    member(h(_, spanish, dog, _, _), Hs),
    member(h(green, _, _, coffee, _), Hs),
    member(h(_, ukrainian, _, tea, _), Hs),
    right_of(h(green, _, _, _, _), h(ivory, _, _, _, _), Hs),
    member(h(_, _, snails, _, oldgold), Hs),
    member(h(yellow, _, _, _, kools), Hs),
    Hs = [_, _, h(_, _, _, milk, _), _, _],
    Hs = [h(_, norwegian, _, _, _)|_],
    next_to(h(_, _, _, _, chesterfield), h(_, _, fox, _, _), Hs),
    next_to(h(_, _, _, _, kools), h(_, _, horse, _, _), Hs),
    member(h(_, _, _, orange_juice, luckystrike), Hs),
    member(h(_, japanese, _, _, parliament), Hs),
    next_to(h(_, norwegian, _, _, _), h(blue, _, _, _, _), Hs),
    member(h(_, _, zebra, _, _), Hs),
    member(h(_, _, _, water, _), Hs).

right_of(A, B, [B, A|_]).
right_of(A, B, [_|Hs]) :- right_of(A, B, Hs).

next_to(A, B, Hs) :- right_of(A, B, Hs).
next_to(A, B, Hs) :- right_of(B, A, Hs).

zebra(Owner) :- houses(Hs), member(h(_, Owner, zebra, _, _), Hs).
