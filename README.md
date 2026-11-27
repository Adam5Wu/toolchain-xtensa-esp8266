# toolchain-xtensa-esp8266

PlatformIO toolchain package bundling Espressif's `xtensa-esp-elf` **GCC 16.2.0** (`esp-16.2.0_20261109`) Windows x64 compiler binaries with a custom ESP8266 Call0 multilib overlay (`esp8266-custom-multilib.tar.xz`), pruning unused `picolibc/` target libraries.

## Upstream Components

| Component | Source Release (`espressif/crosstool-NG`) | SHA-256 |
| :--- | :--- | :--- |
| Host toolchain (`windows_amd64`) | `xtensa-esp-elf-16.2.0_20261109-x86_64-w64-mingw32.zip` | `8de83704fdcf58189e337cbc63a1167a3c3cc078e193efa7fdc113bdf000c337` |
| Stock target multilib (`esp8266`) | `xtensa-esp-elf-16.2.0_20261109-esp8266-multilib.tar.xz` | `515e90793ba949cfa60d4dd8297862b0a46f5275c024dcc1ac64e3dc2b80b0ba` |
| Linux build host (`ubuntu-latest` CI) | `xtensa-esp-elf-16.2.0_20261109-x86_64-linux-gnu.tar.xz` | `085098d02d56c7b2c8942ccb3c934b610adb57aa5b687e3fc1fc4e26b8f2fe40` |

## Custom Overlay Features

### 1. Full 8-Line `libstdc++-v3` Multilib Matrix
Built across `{newlib, newlib-nano} x {rtti, no-rtti} x {exceptions, no-exceptions}`:
- `xtensa-esp-elf/lib/esp8266/{,no-rtti/}{,no-exceptions/}` (`libstdc++.a`, `libsupc++.a`)
- `newlib-nano/xtensa-esp-elf/lib/esp8266/{,no-rtti/}{,no-exceptions/}` (`libstdc++.a`, `libstdc++_nano.a`, `libsupc++.a`, `libsupc++_nano.a`)
- To link `-fno-exceptions` variants without modifying GCC's built-in `--print-multi-lib` table, pass `-L <lib_root>/esp8266[/no-rtti]/no-exceptions` **before** `-L <lib_root>/esp8266[/no-rtti]` so `libstdc++.a` and `libsupc++.a` resolve from `no-exceptions/` while `-lc`/`-lc_nano`/`-lm`/`crt0.o` fall through to the parent directory.
- **IRQ-safe atomics & `_S_atomic` `shared_ptr`**: configured with `--with-libstdcxx-lock-policy=atomic` (`_GLIBCXX_HAVE_ATOMIC_LOCK_POLICY 1` in `bits/c++config.h`) and patched `atomicity.h` using `rsil 15` / `wsr.ps; rsync` critical sections plus a 5-argument `__atomic_compare_exchange_4` implementation for `std::weak_ptr::lock()`, eliminating `pthread_mutex` / `guard.o` / RTTI pulls from `std::shared_ptr` and `<filesystem>`.
- **LittleFS / Newlib `<filesystem>`**: removes `<ext/stdio_filebuf.h>` / `<ostream>` (`do_copy_file` uses a 256 B stack buffer with `::read`/`::write`), disables `use_facet<codecvt<wchar_t, ...>>` in `path::_S_convert_loc`, guards optional `DT_*` macros, handles `st_dev == 0 && st_ino == 0` in `equiv_files()`, closes `DIR*` before `rmdir` in `recursive_directory_iterator::__erase()`, and falls back to `::rmdir` on `EISDIR`/`EPERM` in `fs::remove()`.

### 2. Patched `newlib-nano` (`libc_nano.a`)
- **Unconditional 64-bit integer & C99 formatting**: enables `%lld`, `%llu`, `%llx`, `%llX`, `%llo`, `%jd`, `%lln`, `%z`, `%t`, and true 8-bit `%hh` (`CHARINT`) directly inside `nano-vfprintf` with zero extra linker flags (targeting ESP8266 Mask ROM `__udivdi3`/`__umoddi3`).
- **Safe `<f>` placeholder & opt-in float**: when `_printf_float` is not linked, floating-point specifiers (`%e`/`%f`/`%g`) drain the `va_list` argument cleanly and emit `"<f>"`; full floating-point formatting remains opt-in via `-Wl,-u,_printf_float`.

## Usage Notes (ESP8266 Call0 ABI)

- Select the ESP8266 multilib with `-mdynconfig=xtensa_esp8266.so` (and `-fno-rtti` for `esp8266/no-rtti`), and include `<package_dir>/lib` on `PATH` with `XTENSA_GNU_CONFIG` **unset** so `cc1.exe`, `cc1plus.exe`, `as.exe`, and `ld.exe` load the dynconfig plugin reliably.
- Do **not** pass an absolute path to `-mdynconfig=` (GCC's multilib matcher expects the literal `xtensa_esp8266.so` from `-print-multi-lib` and otherwise falls back to the default `.` windowed multilib), and do **not** combine `XTENSA_GNU_CONFIG=<abs>` with `-mdynconfig=xtensa_esp8266.so` (`cc1.exe` aborts when they differ as strings).
- Re-pack reproducibly with `python scripts/build_package.py --custom-overlay esp8266-custom-multilib.tar.xz`.

## Verification & Provenance

Release archives are built and attested on GitHub Actions. Consumers can verify the Windows archive against SLSA build provenance using the GitHub CLI:

```sh
gh attestation verify toolchain-xtensa-esp8266-windows_amd64-16.2.0-esp8266.1.zip -R Adam5Wu/toolchain-xtensa-esp8266
```

See [RELEASE.md](RELEASE.md) for the CI gating, ELF/ABI audit suite, and release process.
