#!/usr/bin/env bash
# Repackage an official upstream Neovim prebuilt release tarball into a .deb.
#
# Usage: build-deb.sh <version> <arch> [package_revision]
#   <version>           upstream tag, e.g. v0.12.4
#   <arch>              amd64 | arm64
#   [package_revision]  our packaging revision for this upstream version
#                        (Debian "debian_revision" convention). Defaults to 1.
#                        Bump this to publish a new .deb for the same
#                        upstream Neovim version, e.g. after a packaging-only
#                        fix, without waiting for a new upstream release.

set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <version> <arch> [package_revision]" >&2
  exit 1
fi

version="$1"
arch="$2"
package_revision="${3:-1}"

case "$arch" in
  amd64) upstream_arch="x86_64" ;;
  arm64) upstream_arch="arm64" ;;
  *)
    echo "Unsupported arch: $arch (expected amd64 or arm64)" >&2
    exit 1
    ;;
esac

version_number="${version#v}"
deb_version="${version_number}-${package_revision}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="$repo_root/dist"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

asset="nvim-linux-${upstream_arch}.tar.gz"
url="https://github.com/neovim/neovim/releases/download/${version}/${asset}"

echo "Downloading ${url}"
curl -fL --retry 3 -o "$work_dir/$asset" "$url"

echo "Extracting ${asset}"
tar -xzf "$work_dir/$asset" -C "$work_dir"

extracted_dir="$work_dir/nvim-linux-${upstream_arch}"
if [[ ! -d "$extracted_dir" ]]; then
  echo "Expected extracted directory not found: $extracted_dir" >&2
  exit 1
fi
cd "$extracted_dir"

echo "Building package root"
pkgroot="$extracted_dir/pkgroot"
mkdir -p "$pkgroot/usr" "$pkgroot/DEBIAN"
cp -a bin lib share "$pkgroot/usr/"

# Compress the man page per Debian policy.
gzip -9n "$pkgroot/usr/share/man/man1/nvim.1"

installed_size="$(du -sk "$pkgroot/usr" | cut -f1)"

echo "Detecting runtime dependencies"
mapfile -t elf_files < <(find "$pkgroot/usr/bin" "$pkgroot/usr/lib" -type f \( -name '*.so' -o -perm -u+x \) 2>/dev/null)

declare -A dep_packages=()
for elf in "${elf_files[@]}"; do
  # Skip non-ELF files (e.g. shell scripts) silently.
  if ! ldd "$elf" >/dev/null 2>&1; then
    continue
  fi
  while IFS= read -r libpath; do
    [[ -z "$libpath" ]] && continue
    [[ "$libpath" == *"linux-vdso"* || "$libpath" == *"ld-linux"* ]] && continue
    [[ -e "$libpath" ]] || continue
    # dpkg's file list records canonical paths (e.g. /usr/lib/...), but ldd
    # reports paths through symlinks like /lib -> usr/lib, so resolve first.
    real_libpath="$(readlink -f "$libpath")"
    pkg="$(dpkg -S "$real_libpath" 2>/dev/null | head -n1 | cut -d: -f1 || true)"
    [[ -n "$pkg" ]] && dep_packages["$pkg"]=1
  done < <(ldd "$elf" 2>/dev/null | awk '{ if ($3 ~ /^\//) print $3; else if ($1 ~ /^\//) print $1 }')
done

depends="$(IFS=,; echo "${!dep_packages[*]}" | sed 's/,/, /g')"

echo "Writing control file"
# Debian/Ubuntu split their own neovim package into "neovim" (binary) and
# "neovim-runtime" (arch:all runtime files). This package bundles everything
# into one, so it must claim neovim-runtime's files (desktop entry, icons,
# locale files, ...) to upgrade cleanly over a distro-installed neovim
# instead of dpkg refusing with "trying to overwrite" errors.
cat > "$pkgroot/DEBIAN/control" <<EOF
Package: neovim
Version: ${deb_version}
Section: editors
Priority: optional
Architecture: ${arch}
Depends: ${depends}
Replaces: neovim-runtime
Breaks: neovim-runtime
Installed-Size: ${installed_size}
Maintainer: Neovim Deb Builder <noreply@github.com>
Homepage: https://neovim.io
Description: Heavily optimized vi-like text editor (upstream prebuilt release)
 Unofficial repackaging of the official Neovim prebuilt release binary
 (see https://github.com/neovim/neovim/releases) as a .deb, not affiliated
 with or endorsed by the Neovim project.
EOF

mkdir -p "$dist_dir"
deb_path="$dist_dir/neovim_${deb_version}_${arch}.deb"

echo "Building ${deb_path}"
dpkg-deb --root-owner-group --build "$pkgroot" "$deb_path"

echo "Done: ${deb_path}"
