// Tail-recursive functions that produce clean call+return patterns.
// Using a stripped-down style that avoids clang -O0 shadow-stack spills.

// Use wasm-ld's --export-all flag instead of __attribute__

int factorial_tail(int n, int acc) {
    if (n <= 1) return acc;
    return factorial_tail(n - 1, acc * n);
}

int sum_tail(int n, int acc) {
    if (n <= 0) return acc;
    return sum_tail(n - 1, acc + n);
}

int gcd_tail(int a, int b) {
    if (b == 0) return a;
    return gcd_tail(b, a % b);
}

// NOT tail recursive — for comparison
int fib_tree(int n) {
    if (n <= 1) return n;
    return fib_tree(n - 1) + fib_tree(n - 2);
}
