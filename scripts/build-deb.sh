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

# Debian packages to install inside the build container before running the
# ldd-based dependency-detection loop below, keyed by nothing in particular
# -- just a flat curated allowlist. Empirically verified empty against the
# current upstream release (glibc/libgcc/libm are already present in the
# bare debian:13 image on both amd64 and arm64); if a future Neovim release
# picks up a new shared-library dependency not covered by the base image,
# add the owning package here. The hard-fail check further down guarantees
# this list can't silently fall out of date.
extra_packages=()

# Image used only to run ldd/dpkg-deb so dependency detection and package
# building are reproducible regardless of host OS (this script is expected
# to work from macOS too). debian:13 matches the GitHub Actions runners'
# own native platform (amd64: ubuntu-latest: arm64: ubuntu-24.04-arm), so no
# QEMU emulation is needed for this step.
build_image="${BUILD_IMAGE:-debian:13}"

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
cp -a bin lib "$pkgroot/usr/"

doc_dir="$pkgroot/usr/share/doc/neovim"
mkdir -p "$doc_dir"
cp "$repo_root/debian/copyright" "$doc_dir/copyright"

changelog="$work_dir/changelog.Debian"
sed -e "s/__VERSION__/${deb_version}/g" \
    -e "s/__UPSTREAM_TAG__/${version}/g" \
    -e "s/__ARCH__/${arch}/g" \
    -e "s/__DATE__/$(date -R)/g" \
    "$repo_root/debian/changelog-neovim.template" > "$changelog"
gzip -9n -c "$changelog" > "$doc_dir/changelog.Debian.gz"

installed_size="$(du -sk "$pkgroot/usr" | cut -f1)"

echo "Writing control file"
# Like Debian/Ubuntu's own split of neovim into "neovim" (binary) and
# "neovim-runtime" (arch:all runtime files), this package ships only bin/lib
# and depends on neovim-runtime (built by build-runtime-deb.sh) for the
# arch-independent share/ files. __DEPENDS__ is left unsubstituted here --
# it can't be computed until the ldd-based dependency-detection loop below
# runs inside the build container.
sed -e "s/__VERSION__/${deb_version}/g" \
    -e "s/__ARCH__/${arch}/g" \
    -e "s/__INSTALLED_SIZE__/${installed_size}/g" \
    "$repo_root/debian/control-neovim.template" > "$pkgroot/DEBIAN/control"

deb_name="neovim_${deb_version}_${arch}.deb"
pkgroot_container="/work/$(basename "$extracted_dir")/pkgroot"

cat > "$work_dir/container-build.sh" <<'EOS'
set -euo pipefail

if [[ -n "$EXTRA_PACKAGES" ]]; then
  echo "Installing curated dependency packages: $EXTRA_PACKAGES"
  apt-get update -qq
  # shellcheck disable=SC2086
  apt-get install -y -qq --no-install-recommends $EXTRA_PACKAGES
fi

echo "Detecting runtime dependencies"
mapfile -t elf_files < <(find "$PKGROOT/usr/bin" "$PKGROOT/usr/lib" -type f \( -name '*.so' -o -perm -u+x \) 2>/dev/null)

declare -A dep_packages=()
missing_libs=()
for elf in "${elf_files[@]}"; do
  # Skip non-ELF files (e.g. shell scripts) silently.
  if ! ldd "$elf" >/dev/null 2>&1; then
    continue
  fi
  ldd_output="$(ldd "$elf" 2>/dev/null)"

  if grep -q 'not found$' <<<"$ldd_output"; then
    while IFS= read -r missing_line; do
      missing_libs+=("$elf: ${missing_line# }")
    done < <(grep 'not found$' <<<"$ldd_output")
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
  done < <(awk '{ if ($3 ~ /^\//) print $3; else if ($1 ~ /^\//) print $1 }' <<<"$ldd_output")
done

if [[ ${#missing_libs[@]} -gt 0 ]]; then
  echo "ERROR: ldd reported unresolved shared library dependencies:" >&2
  printf '  %s\n' "${missing_libs[@]}" >&2
  echo "Add the Debian package that owns the missing SONAME(s) to the" >&2
  echo "extra_packages allowlist in scripts/build-deb.sh." >&2
  exit 1
fi

ldd_depends="$(IFS=,; echo "${!dep_packages[*]}" | sed 's/,/, /g')"
depends="neovim-runtime (= ${DEB_VERSION})"
[[ -n "$ldd_depends" ]] && depends="${depends}, ${ldd_depends}"

sed -i "s|__DEPENDS__|${depends}|" "$PKGROOT/DEBIAN/control"

echo "Building ${OUT_DEB}"
dpkg-deb --root-owner-group --build "$PKGROOT" "$OUT_DEB"
EOS

echo "Detecting dependencies and building package inside ${build_image}"
docker run --rm --platform "linux/${arch}" \
  -e "PKGROOT=${pkgroot_container}" \
  -e "DEB_VERSION=${deb_version}" \
  -e "EXTRA_PACKAGES=${extra_packages[*]:-}" \
  -e "OUT_DEB=/work/${deb_name}" \
  -v "$work_dir:/work" \
  "$build_image" bash /work/container-build.sh

mkdir -p "$dist_dir"
deb_path="$dist_dir/$deb_name"
cp "$work_dir/$deb_name" "$deb_path"

echo "Done: ${deb_path}"
