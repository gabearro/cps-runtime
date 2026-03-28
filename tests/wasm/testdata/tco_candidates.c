// Functions with tail-recursive patterns compiled WITHOUT optimization (-O0).
// When compiled with -O0, clang emits opCall + opReturn (no return_call).
// The JIT's automatic TCO pass should detect these and convert them to loops.

// 1. Factorial with accumulator — classic tail recursion
//    factorial_acc(n, 1) = n!
__attribute__((export_name("factorial_acc")))
int factorial_acc(int n, int acc) {
    if (n <= 1) return acc;
    return factorial_acc(n - 1, acc * n);
}

// 2. Sum 1..n with accumulator — simple tail recursion
//    sum_acc(n, 0) = n*(n+1)/2
__attribute__((export_name("sum_acc")))
int sum_acc(int n, int acc) {
    if (n <= 0) return acc;
    return sum_acc(n - 1, acc + n);
}

// 3. GCD (Euclidean) — naturally tail recursive
__attribute__((export_name("gcd")))
int gcd(int a, int b) {
    if (b == 0) return a;
    return gcd(b, a % b);
}

// 4. Power with accumulator — tail recursive
//    power_acc(base, exp, 1) = base^exp
__attribute__((export_name("power_acc")))
int power_acc(int base, int exp, int acc) {
    if (exp <= 0) return acc;
    return power_acc(base, exp - 1, acc * base);
}

// 5. NOT tail recursive — fib (for comparison, should NOT be transformed)
__attribute__((export_name("fib_notail")))
int fib_notail(int n) {
    if (n <= 1) return n;
    return fib_notail(n - 1) + fib_notail(n - 2);
}
