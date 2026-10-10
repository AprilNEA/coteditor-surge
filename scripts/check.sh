#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
xcrun swift-format lint --strict --recursive Package.swift Sources tests
devenv shell -- shellcheck install.sh scripts/*.sh tests/*.sh
devenv shell -- shfmt -d -i 4 -ci install.sh scripts/*.sh tests/*.sh
devenv shell -- actionlint
xcrun swift test
xcrun swift tests/check-syntax.swift .
/bin/sh tests/test-install.sh
