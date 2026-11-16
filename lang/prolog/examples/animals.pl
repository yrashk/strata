% animals.pl: a small expert system. It guesses an animal by asking about
% it, remembers the answers (assert), and stops asking what it knows.
%   ?- identify.                 answer yes. or no. to its questions
%   ?- identify([hair, tawny, dark_spots, eats_meat]).   the facts given: no questions

:- dynamic(known/2).
:- dynamic(asking/1).
asking(yes).

animal(cheetah)   :- mammal, carnivore, is(tawny), is(dark_spots).
animal(tiger)     :- mammal, carnivore, is(tawny), is(black_stripes).
animal(giraffe)   :- ungulate, is(long_neck), is(long_legs), is(dark_spots).
animal(zebra)     :- ungulate, is(black_stripes).
animal(ostrich)   :- bird, \+ is(flies), is(long_neck).
animal(penguin)   :- bird, \+ is(flies), is(swims), is(black_and_white).
animal(albatross) :- bird, is(flies_well).

mammal    :- is(hair), !.
mammal    :- is(gives_milk).
bird      :- is(feathers), !.
bird      :- is(flies), is(lays_eggs).
carnivore :- is(eats_meat), !.
carnivore :- is(pointed_teeth), is(claws), is(forward_eyes).
ungulate  :- mammal, is(hooves), !.
ungulate  :- mammal, is(chews_cud).

% is(F): known, given, or asked
is(F) :- known(F, A), !, A == yes.
is(F) :- asking(no), !, assertz(known(F, no)), fail.
is(F) :- format('Does it have, or is it, ~w? ', [F]),
         read(A), assertz(known(F, A)), A == yes.

identify :-
    retractall(known(_, _)),
    (   animal(A) -> format('It is a ~w.~n', [A]) ; write('I do not know it.'), nl ).

identify(Facts) :-
    retractall(known(_, _)),
    forall(member(F, Facts), assertz(known(F, yes))),
    retractall(asking(_)), assertz(asking(no)),
    (   animal(A) -> format('It is a ~w.~n', [A]) ; write('I do not know it.'), nl ),
    retractall(asking(_)), assertz(asking(yes)).
