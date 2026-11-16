% iso_run.pl: runs the ISO conformance vectors (lang/stralog/tests/iso, on
% the disk under /stralog/iso), one file at a time:
%
%   strata$ stralog -g iso(1,10) /stralog/iso/iso_run    files 1 to 10 of index.pl
%
% (a group at a time, each in a new stralog: what is consulted stays in the
% clause store)
% Each vector v(Name, Expected, Goal) is run inside findall/3, so that its
% bindings are undone before the next. A vector that does not give what it
% expects is printed with what it gave instead (its variables named A, B, ...).

iso(From, To) :-
    consult('/stralog/iso/index'),
    iso_files(All),
    findall(F, (nth1(I, All, F), I >= From, I =< To), Fs),
    iso_all(Fs, 0, 0, P, T),
    format('iso ~d-~d: ~d of ~d vectors pass~n', [From, To, P, T]).

iso_all([], P, T, P, T).
iso_all([F|Fs], P0, T0, P, T) :-
    atom_concat('/stralog/iso/', F, Path),
    consult(Path),
    findall(N-R, (v(N, E, G), iso_check(E, G, R)), Rs),
    iso_count(Rs, P0, T0, P1, T1),
    iso_all(Fs, P1, T1, P, T).

iso_count([], P, T, P, T).
iso_count([N-R|Rs], P0, T0, P, T) :-
    T1 is T0 + 1,
    (   R == pass
    ->  P1 is P0 + 1
    ;   P1 = P0, R = fail(O),
        write('FAIL '), write(N), write(': '), print(O), nl
    ),
    iso_count(Rs, P1, T1, P, T).

iso_check(E, G, R) :-
    catch(iso_outcome(E, G, O), B, O = ball(B)),
    (   iso_judge(E, O) -> R = pass
    ;   copy_term(O, O2), numbervars(O2, 0, _), R = fail(O2)
    ).

iso_outcome(true(C), G, O) :- !,
    (   call(G) -> ( call(C) -> O = true ; O = wrong(C) ) ; O = false ).
iso_outcome(_, G, O) :-
    (   call(G) -> O = true ; O = false ).

iso_judge(true, true).
iso_judge(true(_), true).
iso_judge(false, false).
iso_judge(fail, false).
iso_judge(error(E), ball(error(E2, _))) :- \+ \+ E = E2.
iso_judge(errors(Es), ball(error(E2, _))) :- member(E, Es), \+ \+ E = E2, !.
iso_judge(ball(B), ball(B2)) :- \+ \+ B = B2.
