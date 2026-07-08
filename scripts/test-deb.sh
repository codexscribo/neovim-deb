#!/usr/bin/env bash
# Install, smoke-test, and uninstall built neovim + neovim-runtime .debs
# inside a distro container.
#
# Usage: test-deb.sh <neovim-deb> <neovim-runtime-deb> <expected-version>
# Intended to run as root inside an Ubuntu/Debian Docker container.

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <neovim-deb> <neovim-runtime-deb> <expected-version>" >&2
  exit 1
fi

deb_path="$1"
runtime_deb_path="$2"
expected_version="$3"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[[ -f "$deb_path" ]] || fail "deb file not found: $deb_path"
[[ -f "$runtime_deb_path" ]] || fail "deb file not found: $runtime_deb_path"

export DEBIAN_FRONTEND=noninteractive

# Official Ubuntu Docker images configure dpkg to skip installing man pages
# (and other docs) to keep images small. That's a Docker-image convenience,
# not real-world behavior, and would make our man page check fail here even
# though it lands correctly on a normal install. Disable it for this test.
rm -f /etc/dpkg/dpkg.cfg.d/excludes

apt-get update -qq || fail "apt-get update"

echo "==> Installing distro's stock neovim package"
apt-get install -y neovim || fail "apt-get install (stock neovim)"
command -v nvim >/dev/null 2>&1 || fail "nvim not found on PATH after installing stock package"
stock_version_output="$(nvim --version)"
echo "Stock version: $(echo "$stock_version_output" | head -n1)"

echo "==> Installing $deb_path + $runtime_deb_path over the stock packages (upgrade path)"
apt-get install -y "./${runtime_deb_path}" "./${deb_path}" || fail "apt-get install"

echo "==> Verifying upgrade replaced the stock package"
hash -r
upgraded_version_output="$(nvim --version)"
echo "$upgraded_version_output" | grep -qF "$expected_version" || fail "nvim --version does not reflect the upgrade to '$expected_version'"

echo "==> Verifying installation"
nvim --headless -es -c 'quit' || fail "nvim --headless smoke test failed"

test -f /usr/share/man/man1/nvim.1.gz || fail "man page not installed"

dpkg -s neovim | grep -q "^Status: install ok installed" || fail "dpkg status for neovim is not 'install ok installed'"
dpkg -s neovim-runtime | grep -q "^Status: install ok installed" || fail "dpkg status for neovim-runtime is not 'install ok installed'"

echo "==> Verifying package ownership boundary"
dpkg -S /usr/share/man/man1/nvim.1.gz | grep -q "^neovim-runtime:" || fail "man page is not owned by neovim-runtime"
dpkg -S /usr/share/applications/nvim.desktop | grep -q "^neovim-runtime:" || fail "desktop file is not owned by neovim-runtime"

echo "==> Uninstalling neovim (neovim-runtime should remain)"
apt-get remove -y neovim || fail "apt-get remove neovim"
hash -r

if command -v nvim >/dev/null 2>&1; then
  fail "nvim still present after removing neovim"
fi

# A package with no conffiles (ours has none) is fully purged from dpkg's
# database by a plain "remove", so dpkg -s either reports it unknown or
# reports it in a non-installed (deinstall/config-files) state. Both are
# valid confirmations of removal; only "install ok installed" is a failure.
if dpkg -s neovim 2>/dev/null | grep -q "^Status: install ok installed"; then
  fail "neovim still reports as installed after removal"
fi

# dpkg does not cascade-remove a satisfied dependency on a plain "remove",
# so neovim-runtime must still be installed at this point.
dpkg -s neovim-runtime | grep -q "^Status: install ok installed" || fail "neovim-runtime was unexpectedly removed along with neovim"

echo "==> Uninstalling neovim-runtime"
apt-get remove -y neovim-runtime || fail "apt-get remove neovim-runtime"

if dpkg -s neovim-runtime 2>/dev/null | grep -q "^Status: install ok installed"; then
  fail "neovim-runtime still reports as installed after removal"
fi

echo "PASS: all checks succeeded"
