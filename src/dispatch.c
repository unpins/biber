/* Single-program dispatch for the embedded biber binary.
 *
 * perl's main() expects the first non-option argv to be the script to run. This
 * binary IS biber, so we intercept main and inject the embedded biber driver as
 * that script before perl sees argv:
 *     [argv[0], "/zip/bin/biber", original args...]
 * /zip/bin/biber is served from the blob by the @INC VFS (vfs_miniz.c) -- no
 * script on disk. Unlike perl's multicall dispatch.c there is no applet list:
 * biber is the only program, so every invocation runs it.
 *
 *   ELF (Linux):    -Wl,--wrap=main routes the crt's main() to __wrap_main;
 *                   __real_main is perl's own generated main.
 *   Mach-O (macOS): perl's perlmain.o has _main renamed to _real_main via
 *                   llvm-objcopy --redefine-sym, and this object supplies _main.
 */
#include <stdlib.h>

#define BIBER_SCRIPT "/zip/bin/biber"

static int unpin_run(int argc, char **argv, char **envp,
                     int (*real)(int, char **, char **)) {
    char **nv = malloc((size_t)(argc + 2) * sizeof(char *));
    if (!nv) return real(argc, argv, envp);
    int n = 0;
    nv[n++] = (argc > 0 && argv[0]) ? argv[0] : (char *)"biber";
    nv[n++] = (char *)BIBER_SCRIPT;
    for (int i = 1; i < argc; i++) nv[n++] = argv[i];
    nv[n] = NULL;
    return real(n, nv, envp);
}

#ifdef __APPLE__
extern int real_main(int argc, char **argv, char **envp);
int main(int argc, char **argv, char **envp) {
    return unpin_run(argc, argv, envp, real_main);
}
#else
extern int __real_main(int argc, char **argv, char **envp);
int __wrap_main(int argc, char **argv, char **envp) {
    return unpin_run(argc, argv, envp, __real_main);
}
#endif
