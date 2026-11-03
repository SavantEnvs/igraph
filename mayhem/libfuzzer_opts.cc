// igraph reports a failed allocation as IGRAPH_ENOMEM, so a huge vertex/node count in an input header is a
// handled error, not a defect. libFuzzer's malloc cap (and the RSS cap that -malloc_limit_mb=0 falls back to)
// would report it as one; lift both. This libFuzzer ignores __libfuzzer_extra_options, but re-parses argv
// after LLVMFuzzerInitialize, so the flags go in first and anything given on the command line still wins.
#include <cstdlib>
#include <cstring>

extern "C" int LLVMFuzzerInitialize(int *argc, char ***argv) {
    static const char *const opts[] = {"-malloc_limit_mb=0", "-rss_limit_mb=0"};
    const int nopts = sizeof(opts) / sizeof(opts[0]);
    char **args = static_cast<char **>(std::malloc((*argc + nopts + 1) * sizeof(char *)));
    if (!args) {
        return 0;
    }
    int n = 0;
    args[n++] = (*argv)[0];
    for (int i = 0; i < nopts; i++) {
        args[n++] = strdup(opts[i]);
    }
    for (int i = 1; i < *argc; i++) {
        args[n++] = (*argv)[i];
    }
    args[n] = nullptr;
    *argc = n;
    *argv = args;
    return 0;
}
