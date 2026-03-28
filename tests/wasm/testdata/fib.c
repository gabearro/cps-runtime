// Simple fibonacci for WASM VM testing
__attribute__((export_name("fib")))
int fib(int n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

__attribute__((export_name("factorial")))
int factorial(int n) {
    int result = 1;
    for (int i = 2; i <= n; i++) {
        result *= i;
    }
    return result;
}

// Memory test: sum an array
__attribute__((export_name("sum_array")))
int sum_array(int* arr, int len) {
    int sum = 0;
    for (int i = 0; i < len; i++) {
        sum += arr[i];
    }
    return sum;
}
