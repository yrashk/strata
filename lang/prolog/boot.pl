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

% The answer: Name = Value for each bound variable; variables bound to each
% other as X = Y; true if there is nothing to say.
'$bindings'(Vs) :-
    '$binds'(Vs, [], false, Any),
    (   Any == false -> write(true) ; true ).

'$binds'([], _, Any, Any).
'$binds'([N=V|Vs], Seen, Any0, Any) :-
    (   var(V)
    ->  (   '$seen_var'(Seen, V, M)
        ->  '$sep'(Any0), write(M), write(' = '), write(N),
            Any1 = true, Seen1 = Seen
        ;   Any1 = Any0, Seen1 = [N-V|Seen]
        ),
        '$binds'(Vs, Seen1, Any1, Any)
    ;   '$sep'(Any0), write(N), write(' = '), writeq(V),
        '$binds'(Vs, Seen, true, Any)
    ).

'$seen_var'([M-W|_], V, M) :- W == V, !.
'$seen_var'([_|Ss], V, M) :- '$seen_var'(Ss, V, M).

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
consult(F) :-
    '$open_source'(F, S),
    '$new_consult',
    '$load'(S),
    close(S).

[F|Fs] :- consult([F|Fs]).

'$open_source'(F, S) :- catch(open(F, read, S), _, fail), !.
'$open_source'(F, S) :- atom_concat(F, '.pl', F2), open(F2, read, S).

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
ignore(G) :- ( call(G) -> true ; true ).
forall(C, A) :- \+ ( call(C), \+ call(A) ).
_ ^ G :- call(G).

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

op(P, T, Ns) :- '$op_list'(Ns, P, T).
'$op_list'([], _, _) :- !.
'$op_list'([N|Ns], P, T) :- !, '$op'(P, T, N), '$op_list'(Ns, P, T).
'$op_list'(N, P, T) :- '$op'(P, T, N).

current_op(P, T, N) :-
    '$op_atoms'(L), '$member'(N, L), '$op_defs'(N, Ds), '$member'(P-T, Ds).

% ---- lists ---------------------------------------------------------------------------
'$member'(X, [X|_]).
'$member'(X, [_|T]) :- '$member'(X, T).

append([], L, L).
append([H|T], L, [H|R]) :- append(T, L, R).

member(X, [X|_]).
member(X, [_|T]) :- member(X, T).

memberchk(X, L) :- member(X, L), !.

length(L, N) :- var(N), !, '$len'(L, 0, N).
length(L, N) :- integer(N), N >= 0, '$mklen'(N, L).
'$len'([], N, N).
'$len'([_|T], N0, N) :- N1 is N0 + 1, '$len'(T, N1, N).
'$mklen'(0, L) :- !, L = [].
'$mklen'(N, [_|T]) :- N1 is N - 1, '$mklen'(N1, T).

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
between(L, H, X) :- integer(X), !, X >= L, X =< H.
between(L, H, L) :- L =< H.
between(L, H, X) :- L < H, L1 is L + 1, between(L1, H, X).

succ(X, Y) :- integer(X), !, X >= 0, Y is X + 1.
succ(X, Y) :- Y > 0, X is Y - 1.

plus(X, Y, Z) :- integer(X), integer(Y), !, Z is X + Y.
plus(X, Y, Z) :- integer(X), !, Y is Z - X.
plus(X, Y, Z) :- X is Z - Y.

% ---- atoms -----------------------------------------------------------------------------
atom_concat(A, B, C) :- atomic(A), atomic(B), !,
    atom_codes(A, Ca), atom_codes(B, Cb), append(Ca, Cb, Cc), atom_codes(C, Cc).
atom_concat(A, B, C) :-
    atom_codes(C, Cc), append(Ca, Cb, Cc), atom_codes(A, Ca), atom_codes(B, Cb).

sub_atom(A, B, L, After, Sub) :-
    atom_codes(A, Cs),
    append(Pre, Rest, Cs), append(SubCs, Post, Rest),
    length(Pre, B), length(SubCs, L), length(Post, After),
    atom_codes(Sub, SubCs).

atom_number(A, N) :- atom(A), !,
    atom_codes(A, Cs), catch(number_codes(N, Cs), _, fail).
atom_number(A, N) :- number_codes(N, Cs), atom_codes(A, Cs).

term_to_atom(T, A) :- '$read_atom'(A, T, _).

upcase_atom(A, U) :- atom_codes(A, Cs), '$upc'(Cs, Us), atom_codes(U, Us).
'$upc'([], []).
'$upc'([C|Cs], [U|Us]) :- ( C >= 0'a, C =< 0'z -> U is C - 32 ; U = C ), '$upc'(Cs, Us).

% ---- terms ------------------------------------------------------------------------------
numbervars(T, S, E) :- term_variables(T, Vs), '$numbervars'(Vs, S, E).
'$numbervars'([], E, E).
'$numbervars'(['$VAR'(N)|Vs], N, E) :- N1 is N + 1, '$numbervars'(Vs, N1, E).

% ---- sorting: a stable merge sort --------------------------------------------------------
msort(L, S) :- length(L, N), '$msort'(N, L, S, [], std).
keysort(L, S) :- length(L, N), '$msort'(N, L, S, [], key).
sort(L, S) :- msort(L, S0), '$dedup'(S0, S).
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
findall(T, G, L, Tail) :- findall(T, G, L0), append(L0, Tail, L).

bagof(T, G, L) :-
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
    '$stats'([Calls, H, TR, B, HS, HSl, HB, TS, TSl, TB, CS, CSl, CB, FM, FW, At, Db, Fa, HSize, _]),
    format('calls: ~d~n', [Calls]),
    format('heap: ~d of ~d bytes used; window: ~d spills, ~d slides, ~d bytes moved~n', [H, HSize, HS, HSl, HB]),
    format('trail: ~d bytes used; window: ~d spills, ~d slides, ~d bytes moved~n', [TR, TS, TSl, TB]),
    CPs is (B + 64) // 64,
    format('choicepoints: ~d frames; window: ~d spills, ~d slides, ~d bytes moved~n', [CPs, CS, CSl, CB]),
    format('far cache: ~d misses, ~d write-backs (64-byte lines)~n', [FM, FW]),
    format('atoms: ~d bytes, clauses: ~d bytes, findall: ~d bytes~n', [At, Db, Fa]).

statistics(runtime, [T, 0]) :- '$now'(U), T is U // 1000.
statistics(inferences, N) :- '$stats'([N|_]).
