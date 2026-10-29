#!/usr/bin/env bash
#
# mayhem/build.sh — build libpcap's three OSS-Fuzz harnesses (fuzz_pcap, fuzz_filter, fuzz_both) as
# sanitized libFuzzer binaries plus -standalone reproducers, and the CMake test programs that
# upstream's own TESTrun suite drives (consumed by mayhem/test.sh).
#
# Runs in /mayhem as `mayhem`. Fully offline and idempotent: libpcap has no fetched dependencies and
# every build tree lives under mayhem/ (gitignored via mayhem/.gitignore).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Features that need extra system libraries or hardware are off: they are irrelevant to the offline
# savefile and filter-compiler surface the harnesses exercise, and keep the build hermetic.
CMAKE_COMMON=(-DBUILD_SHARED_LIBS=OFF -DENABLE_REMOTE=OFF -DBUILD_WITH_LIBNL=OFF
              -DDISABLE_DBUS=ON -DDISABLE_BLUETOOTH=ON -DDISABLE_RDMA=ON -DDISABLE_NETMAP=ON
              -DDISABLE_DAG=ON -DDISABLE_SNF=ON -DDISABLE_LINUX_USBMON=ON)

# 1) Test programs (NORMAL flags, no sanitizers) for mayhem/test.sh.
TEST_BUILD="$SRC/mayhem/build-tests"
cmake -S "$SRC" -B "$TEST_BUILD" -DCMAKE_C_COMPILER="$CC" "${CMAKE_COMMON[@]}" \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS"
cmake --build "$TEST_BUILD" -j"$MAYHEM_JOBS" --target filtertest translatetest enumeratetest

# 2) The project itself, sanitized + coverage-instrumented + DWARF<=3, as a static library.
FUZZ_BUILD="$SRC/mayhem/build-fuzz"
cmake -S "$SRC" -B "$FUZZ_BUILD" -DCMAKE_C_COMPILER="$CC" "${CMAKE_COMMON[@]}" \
      -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
cmake --build "$FUZZ_BUILD" -j"$MAYHEM_JOBS" --target pcap_static
LIBPCAP="$(find "$FUZZ_BUILD" -maxdepth 2 -name 'libpcap*.a' | head -n1)"
[ -f "$LIBPCAP" ] || { echo "libpcap static archive not found in $FUZZ_BUILD" >&2; exit 1; }

# 3) Harnesses: leak detection is compiled out (lsan_off.cc), ASan+UBSan stay on.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZ_BUILD/lsan_off.o"
$CC  $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FUZZ_BUILD/standalone_main.o"
for t in fuzz_pcap fuzz_filter fuzz_both; do
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -I"$SRC" -I"$FUZZ_BUILD" \
      -c "$SRC/testprogs/fuzz/$t.c" -o "$FUZZ_BUILD/$t.o"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
      "$FUZZ_BUILD/$t.o" "$FUZZ_BUILD/lsan_off.o" "$LIBPCAP" -o "$SRC/$t"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link \
      "$FUZZ_BUILD/$t.o" "$FUZZ_BUILD/standalone_main.o" "$FUZZ_BUILD/lsan_off.o" "$LIBPCAP" \
      -o "$SRC/$t-standalone"
done
