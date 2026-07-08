#!/usr/bin/env bash
# Install, smoke-test, and uninstall a built neovim .deb inside a distro container.
#
# Usage: test-deb.sh <path-to-deb> <expected-version>
# Intended to run as root inside an Ubuntu/Debian Docker container.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <path-to-deb> <expected-version>" >&2
  exit 1
fi

deb_path="$1"
expected_version="$2"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[[ -f "$deb_path" ]] || fail "deb file not found: $deb_path"

echo "==> Installing $deb_path"
export DEBIAN_FRONTEND=noninteractive

# Official Ubuntu Docker images configure dpkg to skip installing man pages
# (and other docs) to keep images small. That's a Docker-image convenience,
# not real-world behavior, and would make our man page check fail here even
# though it lands correctly on a normal install. Disable it for this test.
rm -f /etc/dpkg/dpkg.cfg.d/excludes

apt-get update -qq || fail "apt-get update"
apt-get install -y "./${deb_path}" || fail "apt-get install"

echo "==> Verifying installation"
command -v nvim >/dev/null 2>&1 || fail "nvim not found on PATH"

version_output="$(nvim --version)"
echo "$version_output" | grep -qF "$expected_version" || fail "nvim --version does not contain expected version '$expected_version'"

nvim --headless -es -c 'quit' || fail "nvim --headless smoke test failed"

test -f /usr/share/man/man1/nvim.1.gz || fail "man page not installed"

dpkg -s neovim | grep -q "^Status: install ok installed" || fail "dpkg status is not 'install ok installed'"

echo "==> Uninstalling"
apt-get remove -y neovim || fail "apt-get remove"
hash -r

if command -v nvim >/dev/null 2>&1; then
  fail "nvim still present after removal"
fi

# A package with no conffiles (ours has none) is fully purged from dpkg's
# database by a plain "remove", so dpkg -s either reports it unknown or
# reports it in a non-installed (deinstall/config-files) state. Both are
# valid confirmations of removal; only "install ok installed" is a failure.
if dpkg -s neovim 2>/dev/null | grep -q "^Status: install ok installed"; then
  fail "neovim still reports as installed after removal"
fi

echo "PASS: all checks succeeded"
