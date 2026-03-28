// Binomial coefficients: C(n, k) = C(n-1, k-1) + C(n-1, k)
// 2-parameter non-tail-recursive function — exercises selfEntryReg with numParams=2.
// Reference: C(25,12) = 5200300

__attribute__((export_name("binom")))
int binom(int n, int k) {
    if (k == 0 || k == n) return 1;
    return binom(n - 1, k - 1) + binom(n - 1, k);
}
