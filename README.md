# toolchain-xtensa-esp8266

PlatformIO toolchain package bundling Espressif's `xtensa-esp-elf` **GCC 16.2.0** (`esp-16.2.0_20261109`) Windows x64 binaries with the official `esp8266-multilib` overlay (`esp8266` and `esp8266/no-rtti` Call0 multilibs + `lib/xtensa_esp8266.so`).

## Upstream Components

| Component | Source Release (`espressif/crosstool-NG`) | SHA-256 |
| :--- | :--- | :--- |
| Host toolchain (`windows_amd64`) | `xtensa-esp-elf-16.2.0_20261109-x86_64-w64-mingw32.zip` | `8de83704fdcf58189e337cbc63a1167a3c3cc078e193efa7fdc113bdf000c337` |
| Target multilib overlay (`esp8266`) | `xtensa-esp-elf-16.2.0_20261109-esp8266-multilib.tar.xz` | `515e90793ba949cfa60d4dd8297862b0a46f5275c024dcc1ac64e3dc2b80b0ba` |

## Usage Notes (ESP8266 Call0 ABI)

- Select the ESP8266 multilib with `-mdynconfig=xtensa_esp8266.so` (and `-fno-rtti` for `esp8266/no-rtti`), and include `<package_dir>/lib` on `PATH` with `XTENSA_GNU_CONFIG` **unset** so `cc1.exe`, `cc1plus.exe`, `as.exe`, and `ld.exe` load the dynconfig plugin reliably.
- Do **not** pass an absolute path to `-mdynconfig=` (GCC's multilib matcher expects the literal `xtensa_esp8266.so` from `-print-multi-lib` and otherwise falls back to the default `.` windowed multilib), and do **not** combine `XTENSA_GNU_CONFIG=<abs>` with `-mdynconfig=xtensa_esp8266.so` (`cc1.exe` aborts when they differ as strings).
- Re-pack reproducibly with `python scripts/build_package.py`.
