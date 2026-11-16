% boot.pl: the part of Stralog written in Prolog. It travels in the far
% section of /bin/stralog.u and is consulted at start-up, before '$start'
% runs. It holds clauses only: start-up has no solve loop yet to run
% directives with.

% ---- start-up: stralog [-g Goal] [File ...] -----------------------------------
'$start' :-
    '$argv'(Args),
    '$args'(Args, Files, Goal),
    '$consult_all'(Files),
    '$run'(Goal).

'$args'([], [], none).
'$args'(['-g', G|As], Fs, goal(G)) :- !, '$args'(As, Fs, _).
'$args'([F|As], [F|Fs], G) :- '$args'(As, Fs, G).

'$consult_all'([]).
'$consult_all'([F|Fs]) :-
    catch(consult(F), E, '$print_exc'(E)),
    '$consult_all'(Fs).

'$run'(none) :- '$toplevel'.
'$run'(goal(A)) :-
    catch('$read_atom'(A, G, _), E, ('$print_exc'(E), halt(1))),
    (   catch(G, E2, ('$print_exc'(E2), halt(1)))
    ->  halt
    ;   write('Warning: goal failed'), nl, halt(1)
    ).

'$read_atom'(A, G, Vs) :-
    atom_concat(A, ' .', A2),
    '$atom_stream'(A2, S),
    read_term(S, G, [variable_names(Vs)]),
    close(S).

% ---- the top level ---------------------------------------------------------------
'$toplevel' :-
    write('Stralog 0.1'), nl,
    repeat,
        write('?- '), flush_output,
        catch(read_term(user_input, Q, [variable_names(Vs)]), E,
              ('$print_exc'(E), fail)),
        '$tl'(Q, Vs),
        Q == end_of_file,
    !,
    halt.

'$tl'(end_of_file, _) :- !, nl.
'$tl'(Q, Vs) :- '$query'(Q, Vs).

'$query'(Q, Vs) :-
    '$choice'(B0),
    catch(Q, E, true),
    '$choice'(B1),
    (   nonvar(E)
    ->  '$print_exc'(E), !
    ;   '$answer'(Vs, B0, B1), !
    ).
'$query'(_, _) :- write('false.'), nl.

'$answer'(Vs, B0, B1) :-
    '$bindings'(Vs),
    (   B1 == B0
    ->  write('.'), nl
    ;   write(' '), flush_output,
        '$reply'(R),
        (   R == ';'
        ->  fail
        ;   write('.'), nl
        )
    ).

% The answer: Name = Value for each variable that is bound, with the query's
% variables in the values written by their names and other variables as _A,
% _B, ...; true if there is nothing to say.
'$bindings'(Vs) :-
    \+ \+ ( '$name_vars'(Vs),
            term_variables(Vs, Fresh), '$name_fresh'(Fresh, 0),
            '$binds'(Vs, false, Any),
            ( Any == false -> write(true) ; true ) ).

'$name_vars'([]).
'$name_vars'([N=V|Vs]) :- ( var(V) -> V = '$VAR'(N) ; true ), '$name_vars'(Vs).

'$name_fresh'([], _).
'$name_fresh'([V|Vs], I) :-
    L is 0'A + I mod 26, J is I // 26,
    (   J =:= 0 -> atom_codes(N, [0'_, L]) ; number_codes(J, Js), atom_codes(N, [0'_, L|Js]) ),
    V = '$VAR'(N), I1 is I + 1, '$name_fresh'(Vs, I1).

'$binds'([], Any, Any).
'$binds'([N=V|Vs], Any0, Any) :-
    (   V == '$VAR'(N)
    ->  '$binds'(Vs, Any0, Any)
    ;   '$sep'(Any0), write(N), write(' = '),
        write_term(V, [quoted(true), numbervars(true), priority(699)]),
        '$binds'(Vs, true, Any)
    ).

'$sep'(false) :- !.
'$sep'(true) :- write(', ').

% What the user typed after an answer: the first character of the line that
% is not a space (end_of_file at the end of the input).
'$reply'(R) :-
    get_char(C),
    (   C == end_of_file -> R = C
    ;   C == '\n' -> R = C
    ;   C == ' ' -> '$reply'(R)
    ;   R = C, '$skip_line'
    ).

'$skip_line' :-
    get_char(C),
    (   C == '\n' -> true
    ;   C == end_of_file -> true
    ;   '$skip_line'
    ).

'$print_exc'(error(existence_error(procedure, PI), _)) :- !,
    write('Error: unknown procedure '), writeq(PI), nl.
'$print_exc'(error(syntax_error(M), _)) :- !,
    write('Syntax error: '), write(M), nl.
'$print_exc'(error(E, _)) :- !,
    write('Error: '), writeq(E), nl.
'$print_exc'(E) :-
    write('Error: uncaught '), writeq(E), nl.

% ---- consulting ---------------------------------------------------------------------
consult(F) :- var(F), !, throw(error(instantiation_error, consult/1)).
consult([]) :- !.
consult([F|Fs]) :- !, consult(F), consult(Fs).
consult(user) :- !,            % clauses typed in, up to the end of the input (Ctrl-D)
    '$new_consult',
    '$load'(user_input).
consult(F) :-
    '$open_source'(F, S),
    '$new_consult',
    '$load'(S),
    close(S).

[F|Fs] :- consult([F|Fs]).

% F, F.pl, then the same in /stralog (where the examples are)
'$open_source'(F, S) :- catch(open(F, read, S), _, fail), !.
'$open_source'(F, S) :- atom_concat(F, '.pl', F2), catch(open(F2, read, S), _, fail), !.
'$open_source'(F, S) :- atom_concat('/stralog/', F, F3), catch(open(F3, read, S), _, fail), !.
'$open_source'(F, S) :- atom_concat('/stralog/', F, F3), atom_concat(F3, '.pl', F4), open(F4, read, S).

'$load'(S) :-
    repeat,
        catch(read_term(S, T, []), E, ('$load_error'(S, E), fail)),
        '$load_term'(T),
        T == end_of_file,
    !.

'$load_term'(end_of_file) :- !.
'$load_term'((:- D)) :- !,
    (   catch(D, E, ('$print_exc'(E), fail))
    ->  true
    ;   write('Warning: directive failed: '), writeq(D), nl
    ).
'$load_term'((H --> B)) :- !,
    '$dcg_translate'((H --> B), C),
    '$add_clause'(C).
'$load_term'(C) :-
    catch('$add_clause'(C), E, '$print_exc'(E)).

'$load_error'(S, E) :-
    '$line'(S, L),
    write('line '), write(L), write(': '),
    '$print_exc'(E).

% ---- control ------------------------------------------------------------------------
repeat.
repeat :- repeat.

once(G) :- call(G), !.
if(C, T, E) :- ( call(C) *-> call(T) ; call(E) ).
ignore(G) :- ( call(G) -> true ; true ).
forall(C, A) :- \+ ( call(C), \+ call(A) ).
_ ^ G :- call(G).

% ---- lambdas: [X1, ...]>>Goal, called with call/N ------------------------------
% The lambda is copied for each call (its variables are its own, as with
% yall's default), its parameters unified with the arguments; arguments beyond
% the parameters are added to the goal.
'>>'(Ps, B) :- copy_term(Ps-B, _-B1), call(B1).
'>>'(Ps, B, A1) :- '$lambda'(Ps, B, [A1]).
'>>'(Ps, B, A1, A2) :- '$lambda'(Ps, B, [A1, A2]).
'>>'(Ps, B, A1, A2, A3) :- '$lambda'(Ps, B, [A1, A2, A3]).
'>>'(Ps, B, A1, A2, A3, A4) :- '$lambda'(Ps, B, [A1, A2, A3, A4]).
'>>'(Ps, B, A1, A2, A3, A4, A5) :- '$lambda'(Ps, B, [A1, A2, A3, A4, A5]).

'$lambda'(Ps, B, As) :-
    copy_term(Ps-B, Ps1-B1),
    '$lambda_bind'(Ps1, As, Rest),
    (   Rest == [] -> call(B1) ; G =.. [call, B1|Rest], call(G) ).

'$lambda_bind'([], As, As) :- !.
'$lambda_bind'([P|Ps], [A|As], Rest) :- !, P = A, '$lambda_bind'(Ps, As, Rest).
'$lambda_bind'(_, [], []).

% ---- the database ------------------------------------------------------------------
clause(H, B) :- '$clauses'(H, Rs), '$member'(R, Rs), '$clause'(R, H, B).

retract((H :- B)) :- !,
    '$clauses'(H, Rs), '$member'(R, Rs), '$clause'(R, H, B), '$erase'(R).
retract(H) :-
    '$clauses'(H, Rs), '$member'(R, Rs), '$clause'(R, H, true), '$erase'(R).

retractall(H) :-
    '$clauses'(H, Rs), '$member'(R, Rs), '$clause'(R, H, _), '$erase'(R), fail.
retractall(H) :-
    functor(H, N, A), '$dynamic'(N, A).

abolish(N/A) :- functor(H, N, A), retractall(H).

dynamic(Spec) :- '$dyn'(Spec).
'$dyn'(V) :- var(V), !, throw(error(instantiation_error, dynamic/1)).
'$dyn'((A, B)) :- !, '$dyn'(A), '$dyn'(B).
'$dyn'([]) :- !.
'$dyn'([A|B]) :- !, '$dyn'(A), '$dyn'(B).
'$dyn'(N/A) :- '$dynamic'(N, A).
discontiguous(_).

current_predicate(N/A) :- '$preds'(L), '$member'(N/A, L).

op(P, T, Ns) :-
    (   var(P) -> throw(error(instantiation_error, op/3)) ; true ),
    (   var(T) -> throw(error(instantiation_error, op/3)) ; true ),
    (   integer(P) -> true ; throw(error(type_error(integer, P), op/3)) ),
    (   P >= 0, P =< 1200 -> true ; throw(error(domain_error(operator_priority, P), op/3)) ),
    (   atom(T) -> true ; throw(error(type_error(atom, T), op/3)) ),
    (   memberchk(T, [xfx, xfy, yfx, fy, fx, xf, yf]) -> true
    ;   throw(error(domain_error(operator_specifier, T), op/3))
    ),
    (   Ns == [] -> throw(error(permission_error(create, operator, []), op/3)) ; true ),
    '$op_names'(Ns, Names),
    '$op_bar'(Names, P, T),
    '$op_list'(Names, P, T).

% | can only be an infix operator of priority 1001 or more
'$op_bar'(Ns, P, T) :-
    (   memberchk('|', Ns), ( P < 1001 ; \+ memberchk(T, [xfx, xfy, yfx]) )
    ->  throw(error(permission_error(create, operator, '|'), op/3))
    ;   true
    ).

'$op_names'(N, _) :- var(N), !, throw(error(instantiation_error, op/3)).
'$op_names'([], []) :- !.
'$op_names'([N|Ns], [N|Ms]) :- !, '$op_name'(N), '$op_names'(Ns, Ms).
'$op_names'(N, [N]) :- atom(N), !, '$op_name'(N).
'$op_names'(N, _) :- throw(error(type_error(list, N), op/3)).

'$op_name'(N) :- var(N), !, throw(error(instantiation_error, op/3)).
'$op_name'(N) :- \+ atom(N), !, throw(error(type_error(atom, N), op/3)).
'$op_name'(',') :- !, throw(error(permission_error(modify, operator, ','), op/3)).
'$op_name'([]) :- !, throw(error(permission_error(create, operator, []), op/3)).
'$op_name'(_).

'$op_list'([], _, _).
'$op_list'([N|Ns], P, T) :- '$op'(P, T, N), '$op_list'(Ns, P, T).

current_op(P, T, N) :-
    (   var(P) -> true
    ;   integer(P), P >= 0, P =< 1200 -> true
    ;   throw(error(domain_error(operator_priority, P), current_op/3))
    ),
    (   var(T) -> true
    ;   memberchk(T, [xfx, xfy, yfx, fy, fx, xf, yf]) -> true
    ;   throw(error(domain_error(operator_specifier, T), current_op/3))
    ),
    (   var(N) -> true ; atom(N) -> true ; throw(error(type_error(atom, N), current_op/3)) ),
    '$op_atoms'(L), '$member'(N, L), '$op_defs'(N, Ds), '$member'(P-T, Ds).

% ---- lists ---------------------------------------------------------------------------
'$member'(X, [X|_]).
'$member'(X, [_|T]) :- '$member'(X, T).

append([], L, L).
append([H|T], L, [H|R]) :- append(T, L, R).

member(X, [X|_]).
member(X, [_|T]) :- member(X, T).

memberchk(X, L) :- member(X, L), !.

length(L, N) :-
    '$skip'(L, 0, K, T),
    (   nonvar(N), \+ integer(N) -> throw(error(type_error(integer, N), length/2)) ; true ),
    (   integer(N), N < 0 -> throw(error(domain_error(not_less_than_zero, N), length/2)) ; true ),
    (   T == [] -> N = K
    ;   var(T) -> ( integer(N) -> M is N - K, M >= 0, '$mklen'(M, T) ; '$lenv'(T, K, N) )
    ;   throw(error(type_error(list, L), length/2))
    ).
'$lenv'([], N, N).
'$lenv'([_|T], K, N) :- K1 is K + 1, '$lenv'(T, K1, N).
'$mklen'(0, L) :- !, L = [].
'$mklen'(N, [_|T]) :- N1 is N - 1, '$mklen'(N1, T).

% '$skip'(L, 0, K, T): L is K pairs and then T (not a pair)
'$skip'(L, K0, K, T) :-
    (   nonvar(L), L = [_|R] -> K1 is K0 + 1, '$skip'(R, K1, K, T) ; K = K0, T = L ).

% a list, or an error: instantiation if it is partial, type otherwise
'$must_list'(L, P) :-
    '$skip'(L, 0, _, T),
    (   T == [] -> true
    ;   var(T) -> throw(error(instantiation_error, P))
    ;   throw(error(type_error(list, L), P))
    ).
% a list or a partial list, or a type error
'$may_list'(L, P) :-
    '$skip'(L, 0, _, T),
    (   ( T == [] ; var(T) ) -> true ; throw(error(type_error(list, L), P)) ).

reverse(L, R) :- '$rev'(L, [], R).
'$rev'([], A, A).
'$rev'([H|T], A, R) :- '$rev'(T, [H|A], R).

nth0(I, L, E) :- integer(I), !, I >= 0, '$nth'(I, L, E).
nth0(I, L, E) :- var(I), '$nthv'(L, E, 0, I).
nth1(I, L, E) :- integer(I), !, I0 is I - 1, nth0(I0, L, E).
nth1(I, L, E) :- var(I), '$nthv'(L, E, 1, I).
'$nth'(0, [E|_], E) :- !.
'$nth'(I, [_|T], E) :- I1 is I - 1, '$nth'(I1, T, E).
'$nthv'([E|_], E, I, I).
'$nthv'([_|T], E, I0, I) :- I1 is I0 + 1, '$nthv'(T, E, I1, I).

last([X], X) :- !.
last([_|T], X) :- last(T, X).

select(X, [X|T], T).
select(X, [H|T], [H|R]) :- select(X, T, R).

selectchk(X, L, R) :- select(X, L, R), !.

permutation([], []).
permutation(L, [X|P]) :- select(X, L, R), permutation(R, P).

delete([], _, []).
delete([X|T], Y, R) :- X \= Y, !, R = [X|R1], delete(T, Y, R1).
delete([_|T], Y, R) :- delete(T, Y, R).

exclude(_, [], []).
exclude(P, [X|Xs], R) :- ( call(P, X) -> R = R1 ; R = [X|R1] ), exclude(P, Xs, R1).
include(_, [], []).
include(P, [X|Xs], R) :- ( call(P, X) -> R = [X|R1] ; R = R1 ), include(P, Xs, R1).

maplist(_, []).
maplist(G, [A|As]) :- call(G, A), maplist(G, As).
maplist(_, [], []).
maplist(G, [A|As], [B|Bs]) :- call(G, A, B), maplist(G, As, Bs).
maplist(_, [], [], []).
maplist(G, [A|As], [B|Bs], [C|Cs]) :- call(G, A, B, C), maplist(G, As, Bs, Cs).

foldl(_, [], A, A).
foldl(G, [X|Xs], A0, A) :- call(G, X, A0, A1), foldl(G, Xs, A1, A).

sum_list(L, S) :- '$sum'(L, 0, S).
'$sum'([], S, S).
'$sum'([X|Xs], S0, S) :- S1 is S0 + X, '$sum'(Xs, S1, S).

max_list([X|Xs], M) :- '$maxl'(Xs, X, M).
'$maxl'([], M, M).
'$maxl'([X|Xs], M0, M) :- M1 is max(M0, X), '$maxl'(Xs, M1, M).
min_list([X|Xs], M) :- '$minl'(Xs, X, M).
'$minl'([], M, M).
'$minl'([X|Xs], M0, M) :- M1 is min(M0, X), '$minl'(Xs, M1, M).

numlist(L, H, []) :- L > H, !.
numlist(L, H, [L|T]) :- L1 is L + 1, numlist(L1, H, T).

is_list(X) :- var(X), !, fail.
is_list([]).
is_list([_|T]) :- is_list(T).

% ---- arithmetic -----------------------------------------------------------------------
between(L, H, X) :-
    '$int'(L, between/3), '$int'(H, between/3), '$int_or_var'(X, between/3), fail.
between(L, H, X) :- integer(X), !, X >= L, X =< H.
between(L, H, L) :- L =< H.
between(L, H, X) :- L < H, L1 is L + 1, between(L1, H, X).

succ(X, Y) :-
    '$int_or_var'(X, succ/2), '$int_or_var'(Y, succ/2),
    (   var(X), var(Y) -> throw(error(instantiation_error, succ/2)) ; true ),
    (   integer(X), X < 0 -> throw(error(domain_error(not_less_than_zero, X), succ/2)) ; true ),
    (   integer(Y), Y < 0 -> throw(error(domain_error(not_less_than_zero, Y), succ/2)) ; true ),
    (   integer(X) -> Y is X + 1 ; Y > 0, X is Y - 1 ).

plus(X, Y, Z) :-
    '$int_or_var'(X, plus/3), '$int_or_var'(Y, plus/3), '$int_or_var'(Z, plus/3), fail.
plus(X, Y, Z) :- integer(X), integer(Y), !, Z is X + Y.
plus(X, Y, Z) :- integer(X), !, Y is Z - X.
plus(X, Y, Z) :- X is Z - Y.

% ---- atoms -----------------------------------------------------------------------------
atom_codes(A, L) :- '$text_list'(L, codes, atom_codes/2), '$atom_codes'(A, L).
atom_chars(A, L) :- '$text_list'(L, chars, atom_chars/2), '$atom_chars'(A, L).

% the list of a text predicate: a list or a partial list, of codes or chars
'$text_list'(L, How, P) :-
    '$may_list'(L, P), '$text_elems'(L, How, P).
'$text_elems'(L, _, _) :- var(L), !.
'$text_elems'([], _, _).
'$text_elems'([E|Es], How, P) :-
    (   var(E) -> true
    ;   How == codes -> ( integer(E) -> true ; throw(error(type_error(integer, E), P)) )
    ;   atom(E), atom_length(E, 1) -> true
    ;   throw(error(type_error(character, E), P))
    ),
    '$text_elems'(Es, How, P).

atom_concat(A, B, C) :-
    '$atomic_or_var'(A, atom_concat/3), '$atomic_or_var'(B, atom_concat/3),
    '$atomic_or_var'(C, atom_concat/3), fail.
atom_concat(A, B, C) :- atomic(A), atomic(B), !,
    atom_codes(A, Ca), atom_codes(B, Cb), append(Ca, Cb, Cc), atom_codes(C, Cc).
atom_concat(A, B, C) :-
    atom_codes(C, Cc), append(Ca, Cb, Cc), atom_codes(A, Ca), atom_codes(B, Cb).

'$atomic_or_var'(X, _) :- var(X), !.
'$atomic_or_var'(X, _) :- atomic(X), !.
'$atomic_or_var'(X, P) :- throw(error(type_error(atom, X), P)).

'$int_or_var'(X, _) :- var(X), !.
'$int_or_var'(X, _) :- integer(X), !.
'$int_or_var'(X, P) :- throw(error(type_error(integer, X), P)).
'$int'(X, P) :- var(X), !, throw(error(instantiation_error, P)).
'$int'(X, P) :- '$int_or_var'(X, P).

% sub_atom/5 works on codes, and makes an atom only of an answer (atoms are
% never collected)
sub_atom(A, B, L, After, Sub) :-
    (   var(A) -> throw(error(instantiation_error, sub_atom/5)) ; true ),
    (   atom(A) -> true ; throw(error(type_error(atom, A), sub_atom/5)) ),
    (   var(Sub) -> true ; atom(Sub) -> true ; throw(error(type_error(atom, Sub), sub_atom/5)) ),
    atom_codes(A, Cs),
    (   atom(Sub)
    ->  atom_codes(Sub, SubCs),
        append(Pre, Rest, Cs), append(SubCs, Post, Rest),
        length(Pre, B), length(SubCs, L), length(Post, After)
    ;   append(Pre, Rest, Cs), length(Pre, B),
        append(SubCs, Post, Rest), length(SubCs, L), length(Post, After),
        atom_codes(Sub, SubCs)
    ).

% number_codes/2, number_chars/2: the text is read as the reader reads a
% number (0x, 0o, 0b, 0'c, a minus sign, layout before it); '$number_codes'
% and '$number_chars' write one
number_codes(N, L) :- '$num_text'(N, L, codes, number_codes/2).
number_chars(N, L) :- '$num_text'(N, L, chars, number_chars/2).

'$num_text'(N, L, How, P) :-
    (   nonvar(N), \+ integer(N) -> throw(error(type_error(number, N), P)) ; true ),
    '$skip'(L, 0, _, T),
    (   T == [], nonvar(N), \+ ground(L)
    ->  '$num_elems_partial'(L, How, P),
        ( How == codes -> '$number_codes'(N, L0) ; '$number_chars'(N, L0) ), L = L0
    ;   T == []
    ->  '$num_elems'(L, How, P, Cs),
        (   '$num_codes'(Cs, M) -> N = M
        ;   throw(error(syntax_error(illegal_number), P))
        )
    ;   var(T)
    ->  (   var(N) -> throw(error(instantiation_error, P))
        ;   '$num_elems_partial'(L, How, P),
            ( How == codes -> '$number_codes'(N, L0) ; '$number_chars'(N, L0) ), L = L0
        )
    ;   throw(error(type_error(list, L), P))
    ).

'$num_elems'([], _, _, []).
'$num_elems'([E|Es], How, P, [C|Cs]) :- '$num_elem'(E, How, P, C), '$num_elems'(Es, How, P, Cs).
'$num_elems_partial'(L, _, _) :- var(L), !.
'$num_elems_partial'([], _, _).
'$num_elems_partial'([E|Es], How, P) :-
    ( var(E) -> true ; '$num_elem'(E, How, P, _) ), '$num_elems_partial'(Es, How, P).

'$num_elem'(E, _, P, _) :- var(E), !, throw(error(instantiation_error, P)).
'$num_elem'(E, codes, P, E) :- !,
    (   integer(E) -> ( E >= 0, E =< 255 -> true ; throw(error(representation_error(character_code), P)) )
    ;   throw(error(type_error(integer, E), P))
    ).
'$num_elem'(E, chars, P, C) :-
    (   atom(E), atom_length(E, 1) -> char_code(E, C) ; throw(error(type_error(character, E), P)) ).

% '$num_codes'(Cs, N): the codes are a number as the reader reads one:
% layout, an optional minus, then 0'c, 0x.., 0o.., 0b.. or decimal digits
'$num_codes'(Cs, N) :-
    '$num_layout'(Cs, Cs1),
    (   Cs1 = [0'-|Cs2] -> '$num_unsigned'(Cs2, M), N is -M
    ;   '$num_unsigned'(Cs1, N)
    ).
'$num_layout'([C|Cs], R) :- C =< 32, !, '$num_layout'(Cs, R).
'$num_layout'(Cs, Cs).
'$num_unsigned'([0'0, 0''|Cs], N) :- !, '$num_quoted'(Cs, N).
'$num_unsigned'([0'0, 0'x|Cs], N) :- !, '$num_digits'(Cs, 16, 0, N, 0).
'$num_unsigned'([0'0, 0'o|Cs], N) :- !, '$num_digits'(Cs, 8, 0, N, 0).
'$num_unsigned'([0'0, 0'b|Cs], N) :- !, '$num_digits'(Cs, 2, 0, N, 0).
'$num_unsigned'(Cs, N) :- '$num_digits'(Cs, 10, 0, N, 0).
'$num_quoted'([0'', 0''], 0'') :- !.
'$num_quoted'([0'\\, C], N) :- !, '$num_escape'(C, N).
'$num_quoted'([C], C) :- C =\= 0'\\, C =\= 0''.
'$num_escape'(0'n, 10). '$num_escape'(0't, 9). '$num_escape'(0'\\, 0'\\).
'$num_escape'(0'', 0''). '$num_escape'(0'", 0'"). '$num_escape'(0'`, 0'`).
'$num_escape'(0'a, 7). '$num_escape'(0'b, 8). '$num_escape'(0'f, 12).
'$num_escape'(0'v, 11). '$num_escape'(0'r, 13). '$num_escape'(0'0, 0).
'$num_digits'([], _, N, N, K) :- K > 0.
'$num_digits'([C|Cs], R, N0, N, K) :-
    '$digit_value'(C, D), D < R, N1 is N0 * R + D, K1 is K + 1,
    '$num_digits'(Cs, R, N1, N, K1).
'$digit_value'(C, D) :- C >= 0'0, C =< 0'9, !, D is C - 0'0.
'$digit_value'(C, D) :- C >= 0'a, C =< 0'z, !, D is C - 0'a + 10.
'$digit_value'(C, D) :- C >= 0'A, C =< 0'Z, D is C - 0'A + 10.

atom_number(A, N) :- atom(A), !,
    atom_codes(A, Cs), catch(number_codes(N, Cs), _, fail).
atom_number(A, N) :- number_codes(N, Cs), atom_codes(A, Cs).

term_to_atom(T, A) :- '$read_atom'(A, T, _).

upcase_atom(A, U) :- atom_codes(A, Cs), '$upc'(Cs, Us), atom_codes(U, Us).
'$upc'([], []).
'$upc'([C|Cs], [U|Us]) :- ( C >= 0'a, C =< 0'z -> U is C - 32 ; U = C ), '$upc'(Cs, Us).

% ---- terms ------------------------------------------------------------------------------
ground(T) :- term_variables(T, []).
numbervars(T, S, E) :- term_variables(T, Vs), '$numbervars'(Vs, S, E).
'$numbervars'([], E, E).
'$numbervars'(['$VAR'(N)|Vs], N, E) :- N1 is N + 1, '$numbervars'(Vs, N1, E).

% ---- sorting: a stable merge sort --------------------------------------------------------
msort(L, S) :-
    '$must_list'(L, msort/2), '$may_list'(S, msort/2),
    length(L, N), '$msort'(N, L, S, [], std).
keysort(L, S) :-
    '$must_list'(L, keysort/2), '$may_list'(S, keysort/2),
    '$pairs'(L, keysort/2), '$opt_pairs'(S, keysort/2),
    length(L, N), '$msort'(N, L, S, [], key).
sort(L, S) :-
    '$must_list'(L, sort/2), '$may_list'(S, sort/2),
    length(L, N), '$msort'(N, L, S0, [], std), '$dedup'(S0, S).

'$pairs'([], _).
'$pairs'([E|Es], P) :-
    (   var(E) -> throw(error(instantiation_error, P))
    ;   E = _-_ -> '$pairs'(Es, P)
    ;   throw(error(type_error(pair, E), P))
    ).
'$opt_pairs'(L, _) :- var(L), !.
'$opt_pairs'([], _) :- !.
'$opt_pairs'([E|Es], P) :-
    (   var(E) -> true
    ;   E = _-_ -> true
    ;   throw(error(type_error(pair, E), P))
    ),
    '$opt_pairs'(Es, P).
predsort(P, L, S) :- length(L, N), '$msort'(N, L, S0, [], pred(P)), '$pdedup'(S0, S).

% '$msort'(N, L, Sorted, Rest, How): the first N of L sorted; Rest the others
'$msort'(0, L, [], L, _) :- !.
'$msort'(1, [X|L], [X], L, _) :- !.
'$msort'(N, L, S, R, How) :-
    A is N // 2, B is N - A,
    '$msort'(A, L, SA, L1, How), '$msort'(B, L1, SB, R, How),
    '$merge'(SA, SB, S, How).

'$merge'([], L, L, _) :- !.
'$merge'(L, [], L, _) :- !.
'$merge'([X|Xs], [Y|Ys], [Z|Zs], How) :-
    (   '$before'(How, Y, X)
    ->  Z = Y, '$merge'([X|Xs], Ys, Zs, How)
    ;   Z = X, '$merge'(Xs, [Y|Ys], Zs, How)
    ).

'$before'(std, Y, X) :- Y @< X.
'$before'(key, K1-_, K2-_) :- K1 @< K2.
'$before'(pred(P), Y, X) :- call(P, <, Y, X).

'$dedup'([], []).
'$dedup'([X|T], [X|R]) :- '$dedup1'(T, X, R).
'$dedup1'([], _, []).
'$dedup1'([Y|T], X, R) :- ( Y == X -> '$dedup1'(T, X, R) ; R = [Y|R1], '$dedup1'(T, Y, R1) ).
'$pdedup'(L, L).

% ---- all solutions ------------------------------------------------------------------------
findall(T, G, L, Tail) :-
    '$may_list'(L, findall/4), '$may_list'(Tail, findall/4),
    findall(T, G, L0), append(L0, Tail, L).

bagof(T, G, L) :-
    '$may_list'(L, bagof/3),
    '$strip'(G, G1, Ex),
    term_variables(T+Ex, Bound), term_variables(G1, GVs),
    '$free'(GVs, Bound, W),
    (   W == []
    ->  findall(T, G1, L), L \== []
    ;   findall(W-T, G1, Ps), Ps \== [],
        keysort(Ps, Sorted),
        '$groups'(Sorted, Gs),
        '$member'(W-L, Gs)
    ).

setof(T, G, S) :- bagof(T, G, L), sort(L, S).

aggregate_all(count, G, N) :- findall(x, G, L), length(L, N).
aggregate_all(sum(E), G, S) :- findall(E, G, L), sum_list(L, S).
aggregate_all(bag(E), G, L) :- findall(E, G, L).
aggregate_all(set(E), G, S) :- findall(E, G, L), sort(L, S).

'$strip'(G, G, []) :- var(G), !.
'$strip'(V^G, G1, [V|Ex]) :- !, '$strip'(G, G1, Ex).
'$strip'(G, G, []).

'$free'([], _, []).
'$free'([V|Vs], B, R) :-
    ( '$memq'(V, B) -> R = R1 ; R = [V|R1] ), '$free'(Vs, B, R1).

'$memq'(X, [Y|Ys]) :- ( X == Y -> true ; '$memq'(X, Ys) ).

'$groups'([], []).
'$groups'([K-V|T], [K-[V|Vs]|Gs]) :- '$same_key'(T, K, Vs, Rest), '$groups'(Rest, Gs).
'$same_key'([K1-V|T], K, [V|Vs], Rest) :- '$variant'(K1, K), !, K1 = K,
    '$same_key'(T, K, Vs, Rest).
'$same_key'(T, _, [], T).

'$variant'(A, B) :-
    \+ \+ ( copy_term(A, A1), copy_term(B, B1),
            numbervars(A1, 0, N), numbervars(B1, 0, N), A1 == B1 ).

% ---- DCG ----------------------------------------------------------------------------------
'$dcg_translate'((H --> B), (H1 :- B1)) :-
    '$dcg_nt'(H, S0, S, H1), '$dcg_body'(B, S0, S, B1).

'$dcg_nt'(NT, S0, S, G) :- NT =.. L, append(L, [S0, S], L1), G =.. L1.

'$dcg_body'(V, S0, S, phrase(V, S0, S)) :- var(V), !.
'$dcg_body'((A, B), S0, S, (A1, B1)) :- !,
    '$dcg_body'(A, S0, S1, A1), '$dcg_body'(B, S1, S, B1).
'$dcg_body'((A ; B), S0, S, (A1 ; B1)) :- !,
    '$dcg_body'(A, S0, S, A1), '$dcg_body'(B, S0, S, B1).
'$dcg_body'((A -> B), S0, S, (A1 -> B1)) :- !,
    '$dcg_body'(A, S0, S1, A1), '$dcg_body'(B, S1, S, B1).
'$dcg_body'(\+ A, S0, S, (\+ A1, S0 = S)) :- !, '$dcg_body'(A, S0, _, A1).
'$dcg_body'({G}, S0, S, (G, S0 = S)) :- !.
'$dcg_body'(!, S0, S, (!, S0 = S)) :- !.
'$dcg_body'([], S0, S, S0 = S) :- !.
'$dcg_body'([X|Xs], S0, S, S0 = L) :- !, append([X|Xs], S, L).
'$dcg_body'(call(G), S0, S, call(G, S0, S)) :- !.
'$dcg_body'(NT, S0, S, G) :- '$dcg_nt'(NT, S0, S, G).

phrase(G, L) :- phrase(G, L, []).
phrase(G, L, R) :- '$dcg_body'(G, S0, S, Goal), S0 = L, S = R, call(Goal).

% ---- output ---------------------------------------------------------------------------------
writeln(X) :- write(X), nl.
tab(N) :- N =< 0, !.
tab(N) :- put_char(' '), N1 is N - 1, tab(N1).

format(F) :- format(F, []).
format(F, Args) :-
    (   atom(F) -> atom_codes(F, Cs) ; Cs = F ),
    (   is_list(Args) -> As = Args ; As = [Args] ),
    '$fmt'(Cs, As).

'$fmt'([], _).
'$fmt'([0'~, C|Cs], As) :- !, '$fmt_d'(C, As, As1), '$fmt'(Cs, As1).
'$fmt'([C|Cs], As) :- char_code(Ch, C), put_char(Ch), '$fmt'(Cs, As).

'$fmt_d'(0'w, [A|As], As) :- write(A).
'$fmt_d'(0'a, [A|As], As) :- write(A).
'$fmt_d'(0'd, [A|As], As) :- write(A).
'$fmt_d'(0'q, [A|As], As) :- writeq(A).
'$fmt_d'(0'p, [A|As], As) :- print(A).
'$fmt_d'(0's, [A|As], As) :- atom_codes(X, A), write(X).
'$fmt_d'(0'n, As, As) :- nl.
'$fmt_d'(0'~, As, As) :- put_char('~').

% ---- statistics -------------------------------------------------------------------------------
statistics :-
    '$stats'([Calls, H, TR, B, HS, HSl, HB, TS, TSl, TB, CS, CSl, CB, FM, FW, At, Db, Fa, HSize, _,
              GCs, GCFreed]),
    format('calls: ~d~n', [Calls]),
    format('heap: ~d of ~d bytes used; window: ~d spills, ~d slides, ~d bytes moved~n', [H, HSize, HS, HSl, HB]),
    format('garbage collections: ~d, ~d bytes given back~n', [GCs, GCFreed]),
    format('trail: ~d bytes used; window: ~d spills, ~d slides, ~d bytes moved~n', [TR, TS, TSl, TB]),
    CPs is (B + 64) // 64,
    format('choicepoints: ~d frames; window: ~d spills, ~d slides, ~d bytes moved~n', [CPs, CS, CSl, CB]),
    format('far cache: ~d misses, ~d write-backs (64-byte lines)~n', [FM, FW]),
    format('atoms: ~d bytes, clauses: ~d bytes, findall: ~d bytes~n', [At, Db, Fa]).

statistics(runtime, [T, 0]) :- '$now'(U), T is U // 1000.
statistics(inferences, N) :- '$stats'([N|_]).
