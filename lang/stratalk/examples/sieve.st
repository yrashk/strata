"sieve.st: the primes below 200, by Eratosthenes' sieve."

| n flags primes |
n := 200.
flags := Array new: n withAll: true.
primes := OrderedCollection new.
2 to: n do: [:i |
    (flags at: i) ifTrue: [
        primes add: i.
        i * i to: n by: i do: [:k | flags at: k put: false]]].
Transcript showln: primes size printString, ' primes: ', primes asArray printString.
