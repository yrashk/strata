% sendmore.pl: SEND + MORE = MONEY, each letter a different digit.
%   ?- sendmore(L).               [S,E,N,D,M,O,R,Y]
% Column by column from the right, with carries: each column's digits are
% chosen just before the column is checked, which prunes early.

sendmore([S,E,N,D,M,O,R,Y]) :-
    Ds0 = [0,1,2,3,4,5,6,7,8,9],
    select(D, Ds0, Ds1), select(E, Ds1, Ds2), select(Y, Ds2, Ds3),
    C1 is (D + E) // 10, Y =:= (D + E) mod 10,
    select(N, Ds3, Ds4), select(R, Ds4, Ds5),
    C2 is (N + R + C1) // 10, E =:= (N + R + C1) mod 10,
    select(O, Ds5, Ds6),
    C3 is (E + O + C2) // 10, N =:= (E + O + C2) mod 10,
    select(S, Ds6, Ds7), S > 0, select(M, Ds7, _), M > 0,
    O =:= (S + M + C3) mod 10, M =:= (S + M + C3) // 10.
