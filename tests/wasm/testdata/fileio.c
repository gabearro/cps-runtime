#include <stdio.h>
#include <string.h>

int main(void) {
    // Write to a file
    FILE *f = fopen("/sandbox/test_output.txt", "w");
    if (!f) {
        printf("ERROR: could not open file for writing\n");
        return 1;
    }
    fprintf(f, "Hello from WASI file I/O!\n");
    fclose(f);

    // Read it back
    f = fopen("/sandbox/test_output.txt", "r");
    if (!f) {
        printf("ERROR: could not open file for reading\n");
        return 2;
    }
    char buf[256];
    if (fgets(buf, sizeof(buf), f)) {
        printf("Read back: %s", buf);
    }
    fclose(f);

    return 0;
}
