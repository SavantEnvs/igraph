#!/usr/bin/env bash
#
# mayhem/build.sh — build igraph's fuzz harnesses (sanitized, DWARF 3), their standalone reproducers,
# and the project's own unit-test suite (normal flags). Runs in the commit image as `mayhem` in /mayhem.
# Re-runnable and offline: all dependencies are the in-image libxml2 + igraph's vendored sources.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

TARGETS="read_edgelist read_dl read_gml read_graphdb read_graphml read_lgl read_ncol read_pajek read_dimacs_flow write_all_gml write_all_graphml bliss edge_connectivity vertex_connectivity vertex_separators basic_properties_directed basic_properties_undirected linear_algos_directed linear_algos_undirected centrality community weighted_centrality weighted_community misc_algos misc_algos_weighted spatial"

# igraph derives its version from `git describe`, which needs upstream's release tags. The savantenvs fork
# carries none, so without them cmake aborts at configure time. Fall back to the newest released version in
# CHANGELOG.md via the (gitignored) IGRAPH_VERSION file, rewritten on every run.
if ! git describe --tags >/dev/null 2>&1 && [ ! -e IGRAPH_VERSION ]; then
  ver="$(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' CHANGELOG.md | head -1)"
  echo "${ver:-0.0.0}-dev+$(git rev-parse --short=8 HEAD 2>/dev/null || echo unknown)" > IGRAPH_VERSION
fi

# igraph's error-handling stack (IGRAPH_FINALLY) calls destructors through `void (*)(void *)`-cast function
# pointers on every input; UBSan's `function` check would halt on all of them. Only that one check is relaxed.
SANITIZER_FLAGS="$SANITIZER_FLAGS${SANITIZER_FLAGS:+ -fno-sanitize=function}"

# 1) Sanitized igraph libraries. CMAKE_BUILD_TYPE=None keeps igraph from forcing its own Release flags
#    (same as upstream's OSS-Fuzz recipe); -O1 matches OSS-Fuzz's default optimisation level.
#    `build/` is the FUZZ library: it is compiled with -fsanitize=fuzzer-no-link, because the SanCov
#    instrumentation must be in the objects themselves (passing -fsanitize=fuzzer only at the final link
#    instruments nothing and Mayhem sees 0 edges). `build-standalone/` is the same library without SanCov,
#    for the run-once reproducers.
FUZZ_COV_FLAGS="-fsanitize=fuzzer-no-link"
for variant in fuzz standalone; do
  if [ "$variant" = fuzz ]; then bdir=build; cov="$FUZZ_COV_FLAGS"; else bdir=build-standalone; cov=""; fi
  cmake -S . -B "$bdir" -G Ninja \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_BUILD_TYPE=None \
    -DCMAKE_C_FLAGS="-O1 $SANITIZER_FLAGS $cov $DEBUG_FLAGS" \
    -DCMAKE_CXX_FLAGS="-O1 $SANITIZER_FLAGS $cov $DEBUG_FLAGS" \
    -DIGRAPH_WARNINGS_AS_ERRORS=OFF -DFLEX_KEEP_LINE_NUMBERS=ON
  cmake --build "$bdir" -j"$MAYHEM_JOBS" --target igraph
done

XML2_LIBS="$(pkg-config --libs libxml-2.0)"
INCS="-I$SRC/build/include -I$SRC/include"

# 2) Harnesses: SanCov-instrumented fuzzer binary + uninstrumented standalone reproducer, each with a
#    leak-sanitizer-off hook; the fuzzer binaries also carry a libFuzzer option hook (malloc cap off).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o /tmp/lsan_off.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/libfuzzer_opts.cc -o /tmp/libfuzzer_opts.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
for t in $TARGETS; do
  $CXX -O1 $SANITIZER_FLAGS $FUZZ_COV_FLAGS $DEBUG_FLAGS $INCS -c "fuzzing/$t.cpp" -o "/tmp/$t.o"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "/tmp/$t.o" /tmp/lsan_off.o /tmp/libfuzzer_opts.o \
    build/src/libigraph.a $XML2_LIBS -o "/mayhem/$t"
  $CXX -O1 $SANITIZER_FLAGS $DEBUG_FLAGS $INCS -c "fuzzing/$t.cpp" -o "/tmp/$t-standalone.o"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "/tmp/$t-standalone.o" /tmp/standalone_main.o /tmp/lsan_off.o \
    build-standalone/src/libigraph.a $XML2_LIBS -o "/mayhem/$t-standalone"
done

# 3) The project's own unit tests, built with igraph's normal Release flags (separate tree).
cmake -S . -B build-tests -G Ninja \
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DBUILD_TESTING=ON -DIGRAPH_WARNINGS_AS_ERRORS=OFF
cmake --build build-tests -j"$MAYHEM_JOBS" --target build_tests
