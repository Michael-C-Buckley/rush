#!/usr/bin/env sh
set -eu

usage() {
  cat <<'USAGE'
usage: scripts/provision-posix-shells.sh --check|--install

Checks or installs optional POSIX comparison shells used by zig build corpus.
The install mode is best-effort and supports common package managers.
USAGE
}

mode=${1:---check}
case "$mode" in
  --check|--install) ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

check_shells() {
  printf 'comparison shell availability:\n'
  for shell in dash bash yash busybox mksh; do
    if command -v "$shell" >/dev/null 2>&1; then
      printf '  %-8s %s\n' "$shell" "$(command -v "$shell")"
    else
      printf '  %-8s missing\n' "$shell"
    fi
  done
  if command -v bash >/dev/null 2>&1; then
    printf '  %-8s available via bash --posix\n' bash-posix
  else
    printf '  %-8s missing\n' bash-posix
  fi
}

if [ "$mode" = "--check" ]; then
  check_shells
  exit 0
fi

if [ "$(id -u)" -ne 0 ] && ! command -v brew >/dev/null 2>&1; then
  echo "install mode needs root for system package managers" >&2
  echo "try: sudo scripts/provision-posix-shells.sh --install" >&2
  exit 1
fi

install_each() {
  installer=$1
  shift
  for pkg in "$@"; do
    if ! sh -c "$installer \"$pkg\""; then
      echo "warning: could not install optional package: $pkg" >&2
    fi
  done
}

if command -v pacman >/dev/null 2>&1; then
  pacman -Sy --noconfirm
  install_each 'pacman -S --needed --noconfirm' dash yash busybox mksh
elif command -v apt-get >/dev/null 2>&1; then
  apt-get update
  install_each 'apt-get install -y' dash yash busybox mksh
elif command -v apk >/dev/null 2>&1; then
  install_each 'apk add' dash yash busybox mksh
elif command -v dnf >/dev/null 2>&1; then
  install_each 'dnf install -y' dash yash busybox mksh
elif command -v brew >/dev/null 2>&1; then
  install_each 'brew install' dash yash busybox mksh
else
  echo "no supported package manager found" >&2
  exit 1
fi

check_shells
