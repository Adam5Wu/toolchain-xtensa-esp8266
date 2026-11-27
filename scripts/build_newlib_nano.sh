#!/usr/bin/env bash
set -euo pipefail

# Build and audit patched newlib-nano (libc_nano.a) for ESP8266 Call0 ABI.
# Optional env:
#   LINUX_TC_TAR   path to cached x86_64-linux-gnu toolchain tarball
#   ESP8266_ML_TAR path to cached esp8266-multilib tarball
#   NEWLIB_SRC_DIR path to pre-fetched espressif/newlib-esp32 checkout (optional)
#   OUT_DIR        output directory for stripped libc.a, libc_nano.a, libg.a, libg_nano.a

TAG="esp-16.2.0_20261109"
NEWLIB_TAG="esp-4.6.0_20261109"
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

# 2. Fetch espressif/newlib-esp32 @ $NEWLIB_TAG & apply patches/newlib-${NEWLIB_TAG}/*.patch
NEWLIB_WORK="$WORKDIR/newlib"
rm -rf "$NEWLIB_WORK"
if [[ -n "${NEWLIB_SRC_DIR:-}" && -d "${NEWLIB_SRC_DIR}" ]]; then
  cp -a "$NEWLIB_SRC_DIR" "$NEWLIB_WORK"
else
  git clone --depth 1 --branch "$NEWLIB_TAG" https://github.com/espressif/newlib-esp32.git "$NEWLIB_WORK"
fi
for p in "$REPO_ROOT/patches/newlib-${NEWLIB_TAG}"/*.patch; do
  echo "Applying patch: $p"
  git -C "$NEWLIB_WORK" apply --check "$p"
  git -C "$NEWLIB_WORK" apply "$p"
done

# 3. Configure & build newlib-nano for esp8266 (matching stock newlib-nano/include/newlib.h)
BUILD_DIR="$WORKDIR/build-newlib-nano"
INSTALL_DIR="$WORKDIR/install-newlib-nano"
rm -rf "$BUILD_DIR" "$INSTALL_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

export CFLAGS_FOR_TARGET="-mdynconfig=xtensa_esp8266.so -mlongcalls -mtext-section-literals -Os -ffunction-sections -fdata-sections -Wno-error=implicit-function-declaration -Wno-implicit-int"
export AR_FOR_TARGET="xtensa-esp-elf-ar"
export RANLIB_FOR_TARGET="xtensa-esp-elf-ranlib"

"$NEWLIB_WORK/configure" \
  --target=xtensa-esp-elf \
  --prefix="$INSTALL_DIR" \
  --disable-multilib \
  --disable-newlib-supplied-syscalls \
  --enable-newlib-reent-small \
  --enable-newlib-retargetable-locking \
  --enable-newlib-multithread \
  --enable-newlib-nano-malloc \
  --enable-newlib-nano-formatted-io \
  --enable-newlib-io-float \
  --disable-newlib-io-long-double \
  --disable-newlib-io-c99-formats \
  --disable-newlib-io-long-long \
  --disable-newlib-io-pos-args \
  --disable-newlib-fseek-optimization \
  --disable-newlib-unbuf-stream-opt \
  --enable-newlib-fvwrite-in-streamio \
  --enable-newlib-atexit-dynamic-alloc \
  --enable-newlib-global-atexit \
  --disable-newlib-register-fini \
  --enable-lite-exit \
  --enable-newlib-iconv \
  --enable-newlib-reent-binary-compat \
  --disable-newlib-wide-orient \
  --disable-nls

make -j"$(nproc)" ARFLAGS=crD all-target-newlib
make ARFLAGS=crD install-target-newlib

# 4. Pre-packaging libc_nano.a audits (§4.2)
LIBC_NANO="$INSTALL_DIR/xtensa-esp-elf/lib/libc.a"
LIBG_NANO="$INSTALL_DIR/xtensa-esp-elf/lib/libg.a"
NL_H="$INSTALL_DIR/xtensa-esp-elf/include/newlib.h"
STOCK_LIBC_NANO="$TC/newlib-nano/xtensa-esp-elf/lib/esp8266/libc_nano.a"
STOCK_NL_H="$TC/newlib-nano/xtensa-esp-elf/include/newlib.h"

test -f "$LIBC_NANO"
test -f "$LIBG_NANO"
test -f "$NL_H"

echo "=== Audit 1: exact newlib.h ABI parity ==="
diff -u "$STOCK_NL_H" "$NL_H"

echo "=== Audit 2: symbol & dependency audit on nano-vfprintf objects ==="
for obj in '^(libc_a-)?nano-vfprintf\.o:' '^(libc_a-)?nano-svfprintf\.o:'; do
  xtensa-esp-elf-nm "$LIBC_NANO" | awk "/${obj}/{p=1} /^$/{p=0} p" | grep -q ' w _printf_float$' || {
    echo "ERROR: weak _printf_float missing in $obj" >&2
    exit 1
  }
  if xtensa-esp-elf-nm -u "$LIBC_NANO" | awk "/${obj}/{p=1} /^$/{p=0} p" | grep -E '_dtoa_r|__adddf3'; then
    echo "ERROR: unwanted float dependency in $obj" >&2
    exit 1
  fi
done
xtensa-esp-elf-nm --defined-only "$LIBC_NANO" | awk '/^(libc_a-)?nano-vfprintf_i\.o:/{p=1} /^$/{p=0} p' | \
  grep -q ' T _printf_float_disabled$' || {
    echo "ERROR: _printf_float_disabled not defined in nano-vfprintf_i.o" >&2
    exit 1
  }
if xtensa-esp-elf-nm -u "$LIBC_NANO" | awk '/^(libc_a-)?nano-vfprintf_i\.o:/{p=1} /^$/{p=0} p' | \
    grep -E '_dtoa_r|__adddf3|_printf_float'; then
  echo "ERROR: unwanted float reference in nano-vfprintf_i.o" >&2
  exit 1
fi

echo "=== Audit 3: nano-vfprintf .text delta budget (<= +350 B) ==="
STOCK_TEXT=$(xtensa-esp-elf-size "$STOCK_LIBC_NANO" | awk '/nano-(s?vfprintf|vfprintf_i)\.o/{sum += $1} END {print sum+0}')
NEW_TEXT=$(xtensa-esp-elf-size "$LIBC_NANO" | awk '/nano-(s?vfprintf|vfprintf_i)\.o/{sum += $1} END {print sum+0}')
DELTA=$((NEW_TEXT - STOCK_TEXT))
echo "nano-vfprintf .text: stock=${STOCK_TEXT} B, new=${NEW_TEXT} B, delta=${DELTA} B (limit <= +350 B)"
if (( STOCK_TEXT == 0 || NEW_TEXT == 0 || DELTA > 350 )); then
  echo "ERROR: .text delta ${DELTA} B exceeds +350 B budget or invalid size" >&2
  exit 1
fi

echo "=== Audit 4: smoke-link tests (default & opt-in _printf_float) ==="
SMOKE_DIR="$WORKDIR/smoke-newlib"
rm -rf "$SMOKE_DIR"
mkdir -p "$SMOKE_DIR/lib"
cp "$LIBC_NANO" "$SMOKE_DIR/lib/libc.a"
cp "$LIBC_NANO" "$SMOKE_DIR/lib/libc_nano.a"

cat > "$SMOKE_DIR/smoke.c" <<'EOF'
#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

volatile int g_keep;

int main(void) {
  char buf[256];
  int n1 = 0;
  signed char n2 = 0;
  long long n3 = 0;
  int r = snprintf(buf, sizeof(buf),
                   "%lld %lld %llu %llx %llX %#llo %#llo %.0llo %#.0llo "
                   "%jd %zu %td %hhx %hhu %hhd %n%hhn%lln %f %d %s %",
                   (long long)INT64_MIN, (long long)-0x100000000LL,
                   (unsigned long long)ULLONG_MAX,
                   0xdeadbeefcafebabeULL, 0x123456789abcdef0ULL,
                   0ULL, 8ULL, 0ULL, 0ULL,
                   (intmax_t)-42, (size_t)123, (ptrdiff_t)-7,
                   (unsigned int)-1, (unsigned int)256, (int)255,
                   &n1, &n2, &n3,
                   3.14, 99, "ok");
  g_keep = r + n1 + n2 + (int)n3 + (int)buf[0];
  return g_keep == 0 ? 1 : 0;
}
EOF

xtensa-esp-elf-gcc -mdynconfig=xtensa_esp8266.so -mlongcalls -mtext-section-literals -Os \
  -ffunction-sections -fdata-sections \
  -isystem "$INSTALL_DIR/xtensa-esp-elf/include" \
  -c "$SMOKE_DIR/smoke.c" -o "$SMOKE_DIR/smoke.o"

# (a) Default link (no -u _printf_float)
xtensa-esp-elf-gcc -mdynconfig=xtensa_esp8266.so -mlongcalls -mtext-section-literals \
  -L"$SMOKE_DIR/lib" -L"$TC/newlib-nano/xtensa-esp-elf/lib/esp8266" \
  -specs=nosys.specs -Wl,--gc-sections -Wl,-Map="$SMOKE_DIR/smoke_default.map" \
  "$SMOKE_DIR/smoke.o" -o "$SMOKE_DIR/smoke_default.elf"

grep -q "$SMOKE_DIR/lib/libc.a" "$SMOKE_DIR/smoke_default.map" || {
  echo "ERROR: Default smoke link did not use patched libc.a" >&2
  exit 1
}
if xtensa-esp-elf-nm --defined-only "$SMOKE_DIR/smoke_default.elf" | grep -E ' (_printf_float|_dtoa_r)$'; then
  echo "ERROR: _printf_float or _dtoa_r unexpectedly linked in default link" >&2
  exit 1
fi
if grep -E 'nano-vfprintf_float\.o|dtoa\.o' "$SMOKE_DIR/smoke_default.map"; then
  echo "ERROR: nano-vfprintf_float.o or dtoa.o pulled into default link" >&2
  exit 1
fi
xtensa-esp-elf-nm --defined-only "$SMOKE_DIR/smoke_default.elf" | grep -q ' T _printf_float_disabled$' || {
  echo "ERROR: _printf_float_disabled not linked in default link" >&2
  exit 1
}

# (b) Opt-in float link (-Wl,-u,_printf_float)
xtensa-esp-elf-gcc -mdynconfig=xtensa_esp8266.so -mlongcalls -mtext-section-literals \
  -L"$SMOKE_DIR/lib" -L"$TC/newlib-nano/xtensa-esp-elf/lib/esp8266" \
  -specs=nosys.specs -Wl,--gc-sections -Wl,-u,_printf_float -Wl,-Map="$SMOKE_DIR/smoke_float.map" \
  "$SMOKE_DIR/smoke.o" -o "$SMOKE_DIR/smoke_float.elf"

xtensa-esp-elf-nm --defined-only "$SMOKE_DIR/smoke_float.elf" | grep -q ' T _printf_float$' || {
  echo "ERROR: _printf_float not linked under -Wl,-u,_printf_float" >&2
  exit 1
}

if [[ -n "${OUT_DIR:-}" ]]; then
  mkdir -p "$OUT_DIR"
  xtensa-esp-elf-strip --strip-debug --enable-deterministic-archives -o "$OUT_DIR/libc.a" "$LIBC_NANO"
  xtensa-esp-elf-strip --strip-debug --enable-deterministic-archives -o "$OUT_DIR/libg.a" "$LIBG_NANO"
  cp "$OUT_DIR/libc.a" "$OUT_DIR/libc_nano.a"
  cp "$OUT_DIR/libg.a" "$OUT_DIR/libg_nano.a"
fi

echo "SUCCESS: newlib-nano built and audited cleanly (delta=${DELTA} B)."
