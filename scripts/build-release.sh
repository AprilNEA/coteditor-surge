#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
case "$#" in
    0) suffix=-local ;;
    3) suffix= ;;
    *)
        printf 'Usage: build-release.sh [DEVELOPER_ID_APPLICATION_IDENTITY NOTARYTOOL_PROFILE KEYCHAIN]\n' >&2
        exit 1
        ;;
esac
version=$(/usr/bin/plutil -extract metadata.version raw Surge.cotsyntax/Info.json)
package="coteditor-surge-$version"
mkdir -p dist
staging=$(mktemp -d "${TMPDIR:-/tmp}/coteditor-surge-release.XXXXXX")
trap 'rm -rf "$staging"' EXIT
trap 'exit 1' HUP INT TERM

for arch in arm64 x86_64; do
    xcrun swift build -c release --triple "$arch-apple-macosx15.0" \
        --scratch-path ".build/release-$arch" --product check-surge
    binary_directory=$(xcrun swift build -c release --triple "$arch-apple-macosx15.0" \
        --scratch-path ".build/release-$arch" --show-bin-path)
    cp "$binary_directory/check-surge" "$staging/check-surge-$arch"
done

mkdir -p "$staging/$package/bin" "$staging/$package/scripts"
xcrun lipo -create "$staging/check-surge-arm64" "$staging/check-surge-x86_64" \
    -output "$staging/$package/bin/check-surge"
if [ "$#" -eq 0 ]; then
    /usr/bin/codesign --force --sign - "$staging/$package/bin/check-surge"
else
    /usr/bin/codesign --force --sign "$1" --options runtime --timestamp --keychain "$3" \
        --identifier com.aprilnea.coteditor-surge.check-surge "$staging/$package/bin/check-surge"
fi
/usr/bin/codesign --verify --strict --all-architectures "$staging/$package/bin/check-surge"
xcrun lipo "$staging/$package/bin/check-surge" -verify_arch arm64 x86_64
"$staging/$package/bin/check-surge" --help
cp -R Surge.cotsyntax examples "$staging/$package/"
cp install.sh README.md "$staging/$package/"
cp scripts/check-surge.sh scripts/check-on-save.applescript scripts/install-lib.sh "$staging/$package/scripts/"
if [ "$#" -eq 3 ]; then
    /usr/bin/ditto -c -k --keepParent "$staging/$package" "$staging/notarize.zip"
    xcrun notarytool submit "$staging/notarize.zip" --keychain-profile "$2" --keychain "$3" --wait \
        --output-format json >"dist/$package-notarization.json"
    cat "dist/$package-notarization.json"
    submission_id=$(/usr/bin/plutil -extract id raw "dist/$package-notarization.json")
    xcrun notarytool log "$submission_id" --keychain-profile "$2" --keychain "$3" "dist/$package-notarization-log.json"
    if [ "$(/usr/bin/plutil -extract status raw "dist/$package-notarization.json")" != Accepted ]; then
        printf 'Apple did not accept this package for notarization.\n' >&2
        exit 1
    fi
    /usr/bin/codesign --verify --strict --all-architectures --check-notarization \
        -R='notarized' "$staging/$package/bin/check-surge"
fi
COPYFILE_DISABLE=1 tar -czf "dist/$package$suffix.tar.gz" -C "$staging" "$package"
/usr/bin/shasum -a 256 "dist/$package$suffix.tar.gz"
