#!/usr/bin/env bash
# Repackage an official upstream Neovim prebuilt release tarball's
# arch-independent runtime files into a .deb.
#
# Usage: build-runtime-deb.sh <version> [package_revision]
#   <version>           upstream tag, e.g. v0.12.4
#   [package_revision]  our packaging revision for this upstream version
#                        (Debian "debian_revision" convention). Defaults to 1.
#                        Bump this to publish a new .deb for the same
#                        upstream Neovim version, e.g. after a packaging-only
#                        fix, without waiting for a new upstream release.

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <version> [package_revision]" >&2
  exit 1
fi

version="$1"
package_revision="${2:-1}"

# share/ is verified byte-for-byte identical between the amd64 and arm64
# upstream release tarballs, so it doesn't matter which arch's tarball we
# pull it from -- always use x86_64.
upstream_arch="x86_64"

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
cp -a share "$pkgroot/usr/"

# Compress the man page per Debian policy.
gzip -9n "$pkgroot/usr/share/man/man1/nvim.1"

installed_size="$(du -sk "$pkgroot/usr" | cut -f1)"

# No dependency-detection loop here: unlike bin/lib, share/ contains no ELF
# binaries or shared libraries -- its only executable is a non-ELF shell
# script (scripts/less.sh), verified directly. Nothing here needs a runtime
# dependency to work.

echo "Writing control file"
# Like Debian/Ubuntu's own split of neovim into "neovim" (binary) and
# "neovim-runtime" (arch:all runtime files), this package ships only the
# arch-independent share/ files. Replaces/Breaks use this package's own
# version as the cutoff (not a hardcoded constant): any neovim older than
# this exact build -- distro stock or one of our own prior bundled releases
# that still shipped share/ itself -- gets its runtime files reclaimed,
# while a split neovim at the same version remains mutually installable.
cat > "$pkgroot/DEBIAN/control" <<EOF
Package: neovim-runtime
Version: ${deb_version}
Section: editors
Priority: optional
Architecture: all
Replaces: neovim (<< ${deb_version})
Breaks: neovim (<< ${deb_version})
Installed-Size: ${installed_size}
Maintainer: Neovim Deb Builder <noreply@github.com>
Homepage: https://neovim.io
Description: Heavily optimized vi-like text editor (upstream prebuilt release) - runtime files
 Unofficial repackaging of the official Neovim prebuilt release runtime
 files (see https://github.com/neovim/neovim/releases) as a .deb, not
 affiliated with or endorsed by the Neovim project.
EOF

mkdir -p "$dist_dir"
deb_path="$dist_dir/neovim-runtime_${deb_version}_all.deb"

echo "Building ${deb_path}"
dpkg-deb --root-owner-group --build "$pkgroot" "$deb_path"

echo "Done: ${deb_path}"
