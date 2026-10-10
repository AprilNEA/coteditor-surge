#!/bin/sh
# %%%{CotEditorXInput=AllText}%%%
# %%%{CotEditorXOutput=Discard}%%%

exec "$(dirname -- "$0")/.check-surge" "$@"
