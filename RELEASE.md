# Release & Verification Process

All distributed binaries for `toolchain-xtensa-esp8266` are built exclusively on GitHub Actions (`ubuntu-latest`) with strict separation between ephemeral `dev` builds and signed-tag Draft Releases. Workstation builds are never uploaded to GitHub Releases.

## Two-Tier CI Workflows

| Workflow | Trigger | Permissions | Outputs & Gates |
| :--- | :--- | :--- | :--- |
| `.github/workflows/build-dev.yml` | `push` on `dev` (`patches/**`, `scripts/**`, `.github/workflows/**`, `package.json`) and `workflow_dispatch` | `contents: read` | Ephemeral `toolchain-windows-amd64` Actions artifact (`retention-days: 7`). No releases created or modified. |
| `.github/workflows/release.yml` | `push` of tag `v*` | `contents: write`, `id-token: write`, `attestations: write` | Draft GitHub Release (`draft: true`) with `.zip`, `.zip.sha256`, `esp8266-custom-multilib.tar.xz`, `esp8266-custom-multilib.tar.xz.sha256`, and SLSA OIDC provenance (`actions/attest-build-provenance`). |

Both entrypoints invoke `.github/workflows/_build.yml`, which:
1. Fetches and SHA-256-verifies upstream Espressif `esp-16.2.0_20261109` (`x86_64-linux-gnu` and `esp8266-multilib`).
2. Builds all 8 `libstdc++-v3` variants (`{newlib, newlib-nano} x {rtti, no-rtti} x {exceptions, no-exceptions}`) in parallel via `scripts/build_libstdcxx_variant.sh`.
3. Builds patched `newlib-nano` (`libc_nano.a`) in parallel via `scripts/build_newlib_nano.sh`.
4. Asserts cross-variant byte-identical `bits/c++config.h` per RTTI slot, ensures regular files only (no symlinks), packs `esp8266-custom-multilib.tar.xz` deterministically, and assembles the pruned Windows x64 archive via `scripts/build_package.py`.

`release.yml` additionally checks out full history (`fetch-depth: 0`), enforces `git merge-base --is-ancestor "$GITHUB_SHA" origin/main` (rejecting stray tags on `dev`), and verifies `${GITHUB_REF_NAME#v}` matches `.version` in `package.json`.

## Pre-Packaging Audits Enforced in CI

### `libstdc++-v3` (`scripts/build_libstdcxx_variant.sh`)
- **`no-exceptions` unwind check**: zero `.eh_frame` and `.gcc_except_table` sections in both `libstdc++.a` and `libsupc++.a` (verified before and after `--strip-debug --enable-deterministic-archives`).
- **`atomicity.o` symbol check**: zero `class_type_info`, `__cxa_guard`, `__cxa_throw`, or `pthread_mutex` references; defines `T __atomic_compare_exchange_4` with zero `__esp8266_atomic_compare_exchange_4` symbol leakage.
- **Filesystem object check**: zero `chmod`, `basic_file`, `ZNSo`, `use_facet`, or `pthread_mutex` references in `(cow-)fs_{dir,ops,path}.o`.
- **`bits/c++config.h` ABI parity**: `_GLIBCXX_HAVE_ATOMIC_LOCK_POLICY` is `1`; `_GLIBCXX_USE_CHMOD`, `_GLIBCXX_USE_CHDIR`, `_GLIBCXX_USE_GETCWD`, and `_GLIBCXX_HAVE_SYS_STATVFS_H` are unset; strict allowlisted `diff -u` against stock `bits/c++config.h`.
- **C++23 smoke link**: compiles and links `-std=gnu++23 -Wl,--gc-sections` exercising `std::filesystem` (`path`, `directory_iterator`, `copy_file`, `remove_all`), `std::shared_ptr`, and `std::weak_ptr::lock()`, verifying zero unwanted locale/iostream/pthread/syscall objects.

### `newlib-nano` (`scripts/build_newlib_nano.sh`)
- **Exact header parity**: `diff -u` against stock `newlib-nano/xtensa-esp-elf/include/newlib.h` must be empty.
- **Weak float hook**: `nano-vfprintf.o` and `nano-svfprintf.o` keep weak `_printf_float` and zero `_dtoa_r`/`__adddf3` references; `nano-vfprintf_i.o` defines `T _printf_float_disabled` with zero `_dtoa_r`/`__adddf3`/`_printf_float` references.
- **Flash size budget**: combined `.text` delta of `nano-vfprintf_i.o` + `nano-vfprintf.o` + `nano-svfprintf.o` vs. stock `libc_nano.a` must be `<= +350 B`.
- **Smoke links**: default link (`-Wl,--gc-sections`) links `_printf_float_disabled` without `_printf_float` or `_dtoa_r`; opt-in link (`-Wl,-u,_printf_float`) links `_printf_float` cleanly.

## Pre-Publish Draft Release Verification & Recovery

1. Open a Squash PR from `dev` to `main` after `build-dev.yml` passes; merge on GitHub.
2. Fast-forward local `main`, create an SSH-signed annotated tag matching `package.json` (`git tag -a v<version> -m v<version>`), push the tag, and reset `origin/dev` to `main`.
3. Wait for `release.yml` to create the Draft Release, then download and verify the exact CI-built assets:
   ```sh
   gh release download v<version> -R Adam5Wu/toolchain-xtensa-esp8266 -D ./draft-rc
   (cd ./draft-rc && sha256sum -c *.sha256)
   gh attestation verify ./draft-rc/toolchain-xtensa-esp8266-windows_amd64-<version>.zip -R Adam5Wu/toolchain-xtensa-esp8266
   gh attestation verify ./draft-rc/esp8266-custom-multilib.tar.xz -R Adam5Wu/toolchain-xtensa-esp8266
   ```
4. Validate firmware build, linker map, footprint, and hardware integration tests against the downloaded Draft Release archive.
5. Publish by metadata toggle only (never re-uploading local binaries):
   ```sh
   gh release edit v<version> -R Adam5Wu/toolchain-xtensa-esp8266 --draft=false
   ```
6. **Failed-draft recovery** (since `main` is protected against force-push and `release.yml` enforces `main` ancestry):
   - Delete the Draft Release (`gh release delete v<version> --yes`) and delete the remote/local tag (`git push origin :refs/tags/v<version>` and `git tag -d v<version>`).
   - Fix the issue on `dev`, verify via `build-dev.yml`, open and merge a new `dev -> main` Squash PR, then re-tag the new `main` commit.

## GCC / Newlib Upgrade & Patch Rebase Checklist

When rebasing onto a newer Espressif crosstool-NG release:
1. Update `TAG`, `NEWLIB_TAG`, and pinned SHA-256 digests in `.github/workflows/_build.yml`, `scripts/build_libstdcxx_variant.sh`, `scripts/build_newlib_nano.sh`, and `scripts/build_package.py`.
2. Rebase `patches/<gcc-tag>/01-esp8266-atomicity.patch` and `02-esp8266-filesystem.patch` onto the new `espressif/gcc` tag, and `patches/newlib-<newlib-tag>/01-nano-vfprintf-int64-c99-float-placeholder.patch` onto the matching `espressif/newlib-esp32` tag.
3. Bump `"version"` in `package.json`, update `README.md` if upstream digests changed, and run `build-dev.yml` on `dev` to verify all §4.1 and §4.2 audits pass before cutting a release PR.
