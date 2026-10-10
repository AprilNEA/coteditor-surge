#!/bin/sh
set -eu

release_root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/install-lib.sh
. "$release_root/scripts/install-lib.sh"
install_surge "$release_root" "$HOME"
