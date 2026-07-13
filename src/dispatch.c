/* Single-program dispatch for the embedded biber binary.
 *
 * perl's main() expects the first non-option argv to be the script to run. This
 * binary IS biber, so we intercept main and inject the embedded biber driver as
 * that script before perl sees argv:
 *     [argv[0], "/zip/bin/biber", original args...]
 * /zip/bin/biber is served from the blob by the @INC VFS (vfs.c) -- no
 * script on disk. Unlike perl's multicall dispatch.c there is no applet list:
 * biber is the only program, so every invocation runs it.
 *
 *   Engine (Linux + macOS, -DUNPIN_DISPATCH_NOWRAP): under the unpin-llvm engine
 *                   every object is LLVM bitcode, so neither `ld --wrap` nor
 *                   `objcopy --redefine-sym` can bind the entry. perlmain's
 *                   `@main` is IR-renamed to `@real_main` and this object
 *                   supplies plain `main`. One path for both platforms.
 *   Off-engine Windows (mingw): -Wl,--wrap=main routes the crt's main() to
 *                   __wrap_main; __real_main is perl's own generated main.
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

#ifdef UNPIN_DISPATCH_NOWRAP
/* Engine (linux + darwin): perlmain's main() is IR-renamed to real_main; we
 * supply the crt entry. Only the FINAL perl link pulls this object in. */
extern int real_main(int argc, char **argv, char **envp);
int main(int argc, char **argv, char **envp) {
    return unpin_run(argc, argv, envp, real_main);
}
#else
/* Off-engine Windows (mingw): -Wl,--wrap=main. */
extern int __real_main(int argc, char **argv, char **envp);
int __wrap_main(int argc, char **argv, char **envp) {
    return unpin_run(argc, argv, envp, __real_main);
}
#endif
