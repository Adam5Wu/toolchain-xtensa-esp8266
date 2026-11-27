#!/usr/bin/env bash
set -euo pipefail

# Build and audit one variant of libstdc++-v3 for ESP8266 Call0 ABI.
# Required env:
#   LIBC       in {newlib, newlib-nano}
#   RTTI       in {rtti, no-rtti}
#   EXCEPTIONS in {exceptions, no-exceptions}
# Optional env:
#   LINUX_TC_TAR   path to cached x86_64-linux-gnu toolchain tarball
#   ESP8266_ML_TAR path to cached esp8266-multilib tarball
#   GCC_SRC_DIR    path to pre-fetched espressif/gcc checkout (optional)
#   OUT_DIR        output directory for stripped libstdc++.a, libsupc++.a, bits/c++config.h

: "${LIBC:?LIBC must be set (newlib|newlib-nano)}"
: "${RTTI:?RTTI must be set (rtti|no-rtti)}"
: "${EXCEPTIONS:?EXCEPTIONS must be set (exceptions|no-exceptions)}"

case "$LIBC" in
  newlib|newlib-nano) ;;
  *) echo "Invalid LIBC: $LIBC" >&2; exit 1 ;;
esac
case "$RTTI" in
  rtti|no-rtti) ;;
  *) echo "Invalid RTTI: $RTTI" >&2; exit 1 ;;
esac
case "$EXCEPTIONS" in
  exceptions|no-exceptions) ;;
  *) echo "Invalid EXCEPTIONS: $EXCEPTIONS" >&2; exit 1 ;;
esac

TAG="esp-16.2.0_20261109"
LINUX_TC_SHA256="085098d02d56c7b2c8942ccb3c934b610adb57aa5b687e3fc1fc4e26b8f2fe40"
ESP8266_ML_SHA256="515e90793ba949cfa60d4dd8297862b0a46f5275c024dcc1ac64e3dc2b80b0ba"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="${WORKDIR:-$PWD/work}"
TC="$WORKDIR/xtensa-esp-elf"
mkdir -p "$WORKDIR"

# 1. Fetch (if not pre-cached), SHA-256 verify, & unpack Linux cross-compiler + stock esp8266 multilib
LINUX_TC_TAR="${LINUX_TC_TAR:-$WORKDIR/linux-tc.tar.xz}"
ESP8266_ML_TAR="${ESP8266_ML_TAR:-$WORKDIR/esp8266-ml.tar.xz}"
if [[ ! -f "$LINUX_TC_TAR" ]]; then
  curl -sfL "https://github.com/espressif/crosstool-NG/releases/download/${TAG}/xtensa-esp-elf-16.2.0_20261109-x86_64-linux-gnu.tar.xz" -o "$LINUX_TC_TAR"
fi
if [[ ! -f "$ESP8266_ML_TAR" ]]; then
  curl -sfL "https://github.com/espressif/crosstool-NG/releases/download/${TAG}/xtensa-esp-elf-16.2.0_20261109-esp8266-multilib.tar.xz" -o "$ESP8266_ML_TAR"
fi
echo "${LINUX_TC_SHA256}  ${LINUX_TC_TAR}" | sha256sum -c -
echo "${ESP8266_ML_SHA256}  ${ESP8266_ML_TAR}" | sha256sum -c -

rm -rf "$TC"
tar -xf "$LINUX_TC_TAR" -C "$WORKDIR"
tar -xf "$ESP8266_ML_TAR" -C "$WORKDIR"

unset XTENSA_GNU_CONFIG
export PATH="$TC/bin:$PATH"
export LD_LIBRARY_PATH="$TC/lib:${LD_LIBRARY_PATH:-}"

# 2. Fetch GCC 16.2.0 source & apply patches
GCC_WORK="$WORKDIR/gcc"
rm -rf "$GCC_WORK"
if [[ -n "${GCC_SRC_DIR:-}" && -d "${GCC_SRC_DIR}" ]]; then
  cp -a "$GCC_SRC_DIR" "$GCC_WORK"
else
  git clone --depth 1 --branch "$TAG" https://github.com/espressif/gcc.git "$GCC_WORK"
fi
for p in "$REPO_ROOT/patches/${TAG}"/*.patch; do
  echo "Applying patch: $p"
  git -C "$GCC_WORK" apply --check "$p"
  git -C "$GCC_WORK" apply "$p"
done

# 3. Derive per-variant compiler flags & sysroot paths
OPT_FLAG="-O2"
INC_EXTRA=""
LIB_ROOT="$TC/xtensa-esp-elf/lib"
if [[ "$LIBC" == "newlib-nano" ]]; then
  OPT_FLAG="-Os"
  INC_EXTRA="-isystem $TC/newlib-nano/xtensa-esp-elf/include"
  LIB_ROOT="$TC/newlib-nano/xtensa-esp-elf/lib"
fi

RTTI_FLAGS=""
RTTI_SUB="esp8266"
if [[ "$RTTI" == "no-rtti" ]]; then
  RTTI_FLAGS="-fno-rtti"
  RTTI_SUB="esp8266/no-rtti"
fi

EXCEPT_FLAGS=""
if [[ "$EXCEPTIONS" == "no-exceptions" ]]; then
  EXCEPT_FLAGS="-fno-exceptions -fno-unwind-tables -fno-asynchronous-unwind-tables"
fi

# 4. Configure & build libstdc++-v3 standalone (matching Espressif ABI + atomic lock policy)
# Provide top-level builddir libgcc/gthr-default.h so GLIBCXX_CHECK_GTHREADS detects __GTHREADS_CXX0X
mkdir -p "$WORKDIR/libgcc"
cp "$GCC_WORK/libgcc/gthr-posix.h" "$WORKDIR/libgcc/gthr-default.h"

BUILD_DIR="$WORKDIR/build-libstdcxx"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

COMMON_FLAGS="-mdynconfig=xtensa_esp8266.so -mlongcalls -mtext-section-literals $OPT_FLAG -ffunction-sections -fdata-sections $INC_EXTRA"

export CC="xtensa-esp-elf-gcc -mdynconfig=xtensa_esp8266.so"
export CXX="xtensa-esp-elf-g++ -mdynconfig=xtensa_esp8266.so"
export AR="xtensa-esp-elf-ar"
export ARFLAGS="crD"
export RANLIB="xtensa-esp-elf-ranlib"
export STRIP="xtensa-esp-elf-strip"
export CPPFLAGS="$INC_EXTRA"
export CFLAGS="$COMMON_FLAGS"
export CXXFLAGS="$COMMON_FLAGS $RTTI_FLAGS $EXCEPT_FLAGS"
export LDFLAGS="-mdynconfig=xtensa_esp8266.so -L$LIB_ROOT/$RTTI_SUB"

"$GCC_WORK/libstdc++-v3/configure" \
  --host=xtensa-esp-elf \
  --with-newlib \
  --disable-shared \
  --disable-multilib \
  --disable-nls \
  --disable-__cxa_atexit \
  --disable-libstdcxx-verbose \
  --disable-libstdcxx-pch \
  --with-libstdcxx-zoneinfo=no \
  --with-libstdcxx-lock-policy=atomic \
  --enable-libstdcxx-time=yes \
  --with-cross-host=x86_64-pc-linux-gnu \
  --with-gxx-include-dir="$TC/xtensa-esp-elf/include/c++/16.2.0" \
  glibcxx_cv_chmod=no \
  glibcxx_cv_chdir=no \
  glibcxx_cv_getcwd=no \
  ac_cv_header_sys_statvfs_h=no

make -j"$(nproc)" ARFLAGS=crD

# 5. Pre-packaging audits (§4.1)
LIBSTD="$BUILD_DIR/src/.libs/libstdc++.a"
LIBSUP="$BUILD_DIR/libsupc++/.libs/libsupc++.a"
CCFG="$BUILD_DIR/include/xtensa-esp-elf/bits/c++config.h"
STOCK_CCFG="$TC/xtensa-esp-elf/include/c++/16.2.0/xtensa-esp-elf/$RTTI_SUB/bits/c++config.h"

test -f "$LIBSTD"
test -f "$LIBSUP"
test -f "$CCFG"
test -f "$STOCK_CCFG"

echo "=== Audit 1: no-exceptions unwind/exception section check ==="
if [[ "$EXCEPTIONS" == "no-exceptions" ]]; then
  if xtensa-esp-elf-readelf -S "$LIBSTD" "$LIBSUP" | grep -E '\.eh_frame|\.gcc_except_table'; then
    echo "ERROR: Found .eh_frame or .gcc_except_table in no-exceptions archive" >&2
    exit 1
  fi
fi

echo "=== Audit 2: atomicity.o symbol check ==="
for lib in "$LIBSTD" "$LIBSUP"; do
  if xtensa-esp-elf-nm -u "$lib" | awk '/^atomicity\.o:/{p=1} /^$/{p=0} p' | \
      grep -E 'class_type_info|__cxa_guard|__cxa_throw|pthread_mutex'; then
    echo "ERROR: Unexpected dependency in atomicity.o of $lib" >&2
    exit 1
  fi
  xtensa-esp-elf-nm --defined-only "$lib" | awk '/^atomicity\.o:/{p=1} /^$/{p=0} p' | \
    grep -q ' T __atomic_compare_exchange_4$' || {
      echo "ERROR: __atomic_compare_exchange_4 missing from atomicity.o of $lib" >&2
      exit 1
    }
  if xtensa-esp-elf-nm "$lib" | grep -F '__esp8266_atomic_compare_exchange_4'; then
    echo "ERROR: __esp8266_atomic_compare_exchange_4 symbol leaked in $lib" >&2
    exit 1
  fi
done

echo "=== Audit 3: (cow-)fs_*.o symbol check ==="
if xtensa-esp-elf-nm -u "$LIBSTD" | awk '/^(cow-)?fs_(dir|ops|path)\.o:/{p=1} /^$/{p=0} p' | \
    grep -E 'chmod|basic_file|ZNSo|use_facet|pthread_mutex'; then
  echo "ERROR: Unexpected dependency in filesystem objects of $LIBSTD" >&2
  exit 1
fi

echo "=== Audit 4: c++config.h macro checks ==="
if grep -E '^#define (_GLIBCXX_USE_(CHMOD|CHDIR|GETCWD)|_GLIBCXX_HAVE_SYS_STATVFS_H)\b' "$CCFG"; then
  echo "ERROR: Disabled syscall macro unexpectedly defined in $CCFG" >&2
  exit 1
fi
grep -q '^#define _GLIBCXX_HAVE_ATOMIC_LOCK_POLICY 1$' "$CCFG" || {
  echo "ERROR: _GLIBCXX_HAVE_ATOMIC_LOCK_POLICY 1 not defined in $CCFG" >&2
  exit 1
}

echo "=== Audit 5: allowlisted c++config.h ABI diff ==="
if diff -u "$STOCK_CCFG" "$CCFG" | grep -E '^[+-](#|/\* #undef)' | grep -vE \
    '^[+-](#define|/\* #undef) (_GLIBCXX_USE_(CHMOD|CHDIR|GETCWD)|_GLIBCXX_HAVE_SYS_STATVFS_H|_GLIBCXX_HAVE_ATOMIC_LOCK_POLICY)\b'; then
  echo "ERROR: Unexpected c++config.h ABI drift!" >&2
  diff -u "$STOCK_CCFG" "$CCFG" || true
  exit 1
fi

echo "=== Audit 6: C++23 compile+link smoke test ==="
SMOKE_DIR="$WORKDIR/smoke"
rm -rf "$SMOKE_DIR"
mkdir -p "$SMOKE_DIR/lib"
cp "$LIBSTD" "$SMOKE_DIR/lib/libstdc++.a"
cp "$LIBSUP" "$SMOKE_DIR/lib/libsupc++.a"

cat > "$SMOKE_DIR/smoke_stubs.c" <<'EOF'
struct utimbuf;
int rmdir(const char *path) { (void)path; return 0; }
int utime(const char *path, const struct utimbuf *times) { (void)path; (void)times; return 0; }
EOF

cat > "$SMOKE_DIR/smoke.cpp" <<'EOF'
#include <cstdlib>
#include <filesystem>
#include <memory>
#include <new>
#include <string>
#include <system_error>

#if !defined(_GLIBCXX_HAVE_ATOMIC_LOCK_POLICY) || _GLIBCXX_HAVE_ATOMIC_LOCK_POLICY != 1
#error "_GLIBCXX_HAVE_ATOMIC_LOCK_POLICY must be 1"
#endif
static_assert(std::__default_lock_policy == std::_S_atomic, "Expected _S_atomic lock policy");

void* operator new(std::size_t s) { return std::malloc(s ? s : 1); }
void* operator new[](std::size_t s) { return std::malloc(s ? s : 1); }
void operator delete(void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }
void operator delete[](void* p) noexcept { std::free(p); }
void operator delete[](void* p, std::size_t) noexcept { std::free(p); }

int main() {
  namespace fs = std::filesystem;
  std::string base("/tmp/test");
  base += "/sub/file_long_enough_to_heap_alloc";
  fs::path p(base);
  std::error_code ec;
  for (fs::directory_iterator it(p, ec), end; !ec && it != end; it.increment(ec)) {
    (void)it->path();
  }
  fs::copy_file(p, p / "copy", fs::copy_options::overwrite_existing, ec);
  fs::remove_all(p, ec);

  auto sp = std::make_shared<int>(42);
  std::weak_ptr<int> wp = sp;
  auto locked = wp.lock();
  return locked ? *locked : (int)base.size();
}
EOF

xtensa-esp-elf-gcc -mdynconfig=xtensa_esp8266.so -mlongcalls -mtext-section-literals \
  "$OPT_FLAG" -ffunction-sections -fdata-sections -c "$SMOKE_DIR/smoke_stubs.c" -o "$SMOKE_DIR/smoke_stubs.o"

xtensa-esp-elf-g++ -mdynconfig=xtensa_esp8266.so -mlongcalls -mtext-section-literals \
  -std=gnu++23 "$OPT_FLAG" $RTTI_FLAGS $EXCEPT_FLAGS -ffunction-sections -fdata-sections \
  -isystem "$BUILD_DIR/include/xtensa-esp-elf" \
  -isystem "$BUILD_DIR/include" \
  $INC_EXTRA \
  -c "$SMOKE_DIR/smoke.cpp" -o "$SMOKE_DIR/smoke.o"

xtensa-esp-elf-g++ -mdynconfig=xtensa_esp8266.so -mlongcalls -mtext-section-literals \
  $RTTI_FLAGS $EXCEPT_FLAGS \
  -L"$SMOKE_DIR/lib" -L"$LIB_ROOT/$RTTI_SUB" \
  -specs=nosys.specs -Wl,--gc-sections -Wl,-Map="$SMOKE_DIR/smoke.map" \
  "$SMOKE_DIR/smoke.o" "$SMOKE_DIR/smoke_stubs.o" \
  -o "$SMOKE_DIR/smoke.elf"

grep -q "$SMOKE_DIR/lib/libstdc++.a" "$SMOKE_DIR/smoke.map" || {
  echo "ERROR: Smoke link did not use newly built libstdc++.a" >&2
  exit 1
}
if awk '/^Archive member included/{p=1} /^Allocating common/{p=0} p' "$SMOKE_DIR/smoke.map" | \
    grep -E 'locale-inst\.o|wlocale-inst\.o|new_handler\.o|guard\.o|basic_file|ostream|format\.o|chmod\.o|chdir\.o|getcwd\.o|statvfs\.o'; then
  echo "ERROR: Unwanted object pulled in smoke link" >&2
  exit 1
fi
if xtensa-esp-elf-nm --defined-only "$SMOKE_DIR/smoke.elf" | grep -E 'pthread_mutex|get_mutex'; then
  echo "ERROR: pthread_mutex / get_mutex linked into smoke.elf" >&2
  exit 1
fi
if [[ "$RTTI" == "no-rtti" && "$EXCEPTIONS" == "no-exceptions" ]]; then
  if awk '/^Archive member included/{p=1} /^Allocating common/{p=0} p' "$SMOKE_DIR/smoke.map" | \
      grep -E 'class_type_info\.o|si_class_type_info\.o|eh_personality\.o|eh_throw\.o'; then
    echo "ERROR: RTTI or EH object pulled in no-rtti/no-exceptions smoke link" >&2
    exit 1
  fi
  if xtensa-esp-elf-readelf -S "$SMOKE_DIR/smoke.elf" | grep -E '\.eh_frame|\.gcc_except_table'; then
    echo "ERROR: Exception tables found in no-rtti/no-exceptions smoke.elf" >&2
    exit 1
  fi
fi
xtensa-esp-elf-nm --defined-only "$SMOKE_DIR/smoke.elf" | grep -q ' T __atomic_compare_exchange_4$' || {
  echo "ERROR: __atomic_compare_exchange_4 not linked in smoke.elf" >&2
  exit 1
}

if [[ -n "${OUT_DIR:-}" ]]; then
  mkdir -p "$OUT_DIR/bits"
  xtensa-esp-elf-strip --strip-debug --enable-deterministic-archives -o "$OUT_DIR/libstdc++.a" "$LIBSTD"
  xtensa-esp-elf-strip --strip-debug --enable-deterministic-archives -o "$OUT_DIR/libsupc++.a" "$LIBSUP"
  if [[ "$EXCEPTIONS" == "no-exceptions" ]]; then
    if xtensa-esp-elf-readelf -S "$OUT_DIR/libstdc++.a" "$OUT_DIR/libsupc++.a" | grep -E '\.eh_frame|\.gcc_except_table'; then
      echo "ERROR: Found .eh_frame or .gcc_except_table after strip" >&2
      exit 1
    fi
  fi
  cp "$CCFG" "$OUT_DIR/bits/c++config.h"
fi

echo "SUCCESS: libstdc++ variant ($LIBC, $RTTI, $EXCEPTIONS) built and audited cleanly."
