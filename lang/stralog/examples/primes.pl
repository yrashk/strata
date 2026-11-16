% primes.pl: primes by trial division and by the sieve.
%   ?- primes(50, Ps).
%   ?- prime(97).
%   ?- nth_prime(100, P).

prime(2).
prime(N) :- N > 2, N mod 2 =\= 0, \+ has_factor(N, 3).

has_factor(N, F) :- F * F =< N, ( N mod F =:= 0 -> true ; F2 is F + 2, has_factor(N, F2) ).

primes(Max, Ps) :- numlist(2, Max, Ns), sieve(Ns, Ps).

sieve([], []).
sieve([P|Xs], [P|Ps]) :- exclude([X]>>(X mod P =:= 0), Xs, Ys), sieve(Ys, Ps).

nth_prime(N, P) :- nth_prime(N, 2, P).
nth_prime(N, C, P) :- ( prime(C) -> N1 is N - 1 ; N1 = N ),
    ( N1 =:= 0 -> P = C ; C1 is C + 1, nth_prime(N1, C1, P) ).
