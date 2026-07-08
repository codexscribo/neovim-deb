# neovim-deb

Unofficial `.deb` packages for [Neovim](https://neovim.io), built from the
**official prebuilt release tarballs** published on the
[neovim/neovim releases page](https://github.com/neovim/neovim/releases).

This repo does **not** compile Neovim from source. It downloads the upstream
`nvim-linux-x86_64.tar.gz` / `nvim-linux-arm64.tar.gz` release assets,
repackages their contents as `/usr/...` inside a Debian package, auto-detects
the correct runtime dependencies (glibc, libicu, etc.) via `ldd`, and
publishes the result as a GitHub Release — nothing more.

This project is **not affiliated with or endorsed by the Neovim project**.

## Install

```sh
curl -LO https://github.com/codexscribo/neovim-deb/releases/latest/download/neovim_<version>_amd64.deb
sudo dpkg -i ./neovim_<version>_amd64.deb
# If dpkg complains about missing dependencies:
sudo apt -f install
```

Replace `amd64` with `arm64` on ARM systems, and `<version>` with the version
number from the release you downloaded (e.g. `0.12.4`).

The package is named `neovim` — the same name Debian/Ubuntu use for their own
`neovim` package — so installing it upgrades or supersedes whatever `neovim`
package (if any) is already installed. No special flags are needed.

## Supported architectures

- `amd64`
- `arm64`

## How it works

1. **`scripts/build-deb.sh <version> <arch>`** downloads the matching upstream
   release tarball, lays its `bin/`, `lib/`, and `share/` directories out
   under `pkgroot/usr/`, compresses the man page, auto-detects runtime
   dependencies with `ldd` + `dpkg -S`, writes a `DEBIAN/control` file, and
   builds the `.deb` with `dpkg-deb`.
2. **`scripts/test-deb.sh <deb> <version>`** installs the distro's own stock
   `neovim` package first, then installs the built package over it to
   exercise the upgrade path, checks that `nvim` runs and reports the right
   version, confirms the man page and `dpkg` metadata are correct, then
   uninstalls it and confirms cleanup.
3. **`.github/workflows/release.yml`** runs on a daily schedule (and can be
   triggered manually). It resolves the latest upstream Neovim release (or a
   specific version passed to `workflow_dispatch`), skips if a matching
   GitHub Release already exists in this repo, builds `.deb`s for both
   architectures, tests each one across Ubuntu 22.04/24.04/26.04 and Debian
   12/13 — including upgrading from each distro's stock `neovim` package —
   and only publishes a GitHub Release if every install/smoke-test
   combination passes.

## Caveats

- This is a repackaging of upstream binaries, not an independently built or
  audited package. Use at your own risk.
- Requires glibc >= 2.34, matching upstream's build requirement — Ubuntu
  22.04+ and Debian 12+. Older releases such as Debian 11 (glibc 2.31)
  can't run the upstream binary at all; this is a limitation of the
  official Neovim release itself, not something this repackaging can work
  around.
- Once installed, `dpkg`/`apt` will consider `neovim` "installed" at this
  package's version. A subsequent `apt upgrade` will **not** automatically
  downgrade you back to your distro's own `neovim` package — you'd need to
  reinstall it explicitly (e.g. `sudo apt install --reinstall neovim`) if you
  ever want to revert.
- No APT repository is provided; packages are distributed only as GitHub
  Release assets.

## License

[MIT](./LICENSE) — applies to the packaging scripts and CI in this repo only,
not to Neovim itself (see [neovim/neovim](https://github.com/neovim/neovim)
for its license).
