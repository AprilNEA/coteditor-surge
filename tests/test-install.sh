#!/bin/sh
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/coteditor-surge-install-test.XXXXXX")
trap 'rm -rf "$temporary"' 0
trap 'exit 130' INT
trap 'exit 143' TERM
release="$temporary/release with spaces"
stubs="$temporary/stubs"
mkdir -p "$release/bin" "$release/scripts" "$stubs" "$temporary/staging"
cp "$root/install.sh" "$release/install.sh"
cp "$root/scripts/check-surge.sh" "$root/scripts/check-on-save.applescript" "$root/scripts/install-lib.sh" "$release/scripts/"
cp -R "$root/Surge.cotsyntax" "$release/Surge.cotsyntax"
cat >"$temporary/install-launcher.sh" <<'LAUNCHER'
#!/bin/sh
set -eu
. "$1/scripts/install-lib.sh"
install_surge "$1" "$2"
LAUNCHER
cat >"$release/bin/check-surge" <<'CHECKER'
#!/bin/sh
printf 'argument:<%s>\n' "$@"
/bin/cat
CHECKER
cat >"$stubs/plutil" <<'PLUTIL'
#!/bin/sh
set -eu
[ "$6" = /Applications/CotEditor.app/Contents/Info.plist ]
[ "$SURGE_TEST_VERSION" != missing ] || exit 1
printf '%s\n' "$SURGE_TEST_VERSION"
PLUTIL
cat >"$stubs/osacompile" <<'OSACOMPILE'
#!/bin/sh
set -eu
: >"$SURGE_TEST_COMPILED"
[ "$1" = -o ]
mkdir -p "$2/Contents/Resources/Scripts"
/bin/cp "$3" "$2/Contents/Resources/Scripts/main.scpt"
[ "$SURGE_TEST_COMPILE_FAILURE" = false ]
OSACOMPILE
cat >"$stubs/cp" <<'COPY'
#!/bin/sh
set -eu
for destination do :; done
if [ -n "$SURGE_TEST_FAIL_COPY" ] && [ "$destination" = "$SURGE_TEST_FAIL_COPY/" ]; then
	printf 'partial copy\n' >"$destination/partial"
	exit 1
fi
exec /bin/cp "$@"
COPY
chmod 755 "$release/bin/check-surge" "$stubs/plutil" "$stubs/osacompile" "$stubs/cp"

fail() {
    printf 'Installer test failed: %s\n' "$1" >&2
    exit 1
}
destinations() {
    syntax="$test_home/Library/Containers/com.coteditor.CotEditor/Data/Library/Application Support/CotEditor/Syntaxes/Surge.cotsyntax"
    scripts="$test_home/Library/Application Scripts/com.coteditor.CotEditor/Surge"
}
run_install() {
    env PATH="$stubs:$PATH" TMPDIR="$temporary/staging" \
        SURGE_TEST_VERSION="$test_version" SURGE_TEST_COMPILED="$temporary/compiled" \
        SURGE_TEST_COMPILE_FAILURE="$compile_failure" SURGE_TEST_FAIL_COPY="$fail_copy" \
        /bin/sh "$temporary/install-launcher.sh" "$release" "$test_home" >"$temporary/output" 2>&1
}
expect_failure() {
    if run_install; then fail 'installation unexpectedly succeeded'; fi
}
assert_absent() {
    [ ! -e "$1" ] && [ ! -L "$1" ] || fail "unexpected destination: $1"
}
assert_staging_empty() {
    for entry in "$temporary/staging"/*; do
        [ ! -e "$entry" ] || fail "temporary files remain: $entry"
    done
}

compile_failure=false
fail_copy=
for test_version in missing 6.9.9 invalid; do
    test_home="$temporary/prerequisite-$test_version"
    expect_failure
    assert_absent "$test_home"
    assert_absent "$temporary/compiled"
done
test_version=7.1.1
test_home="$temporary/no-binary"
mv "$release/bin/check-surge" "$release/bin/check-surge.saved"
expect_failure
assert_absent "$test_home"
assert_absent "$temporary/compiled"
mv "$release/bin/check-surge.saved" "$release/bin/check-surge"
chmod -x "$release/bin/check-surge"
expect_failure
assert_absent "$test_home"
assert_absent "$temporary/compiled"
chmod 755 "$release/bin/check-surge"

test_home="$temporary/home 'and \"quotes\" \\ path"
destinations
run_install || {
    cat "$temporary/output" >&2
    fail 'installation with a quoted home path failed'
}
[ -f "$syntax/Info.json" ] || fail 'syntax package was not copied'
[ -x "$scripts/.check-surge" ] || fail 'helper is not executable'
[ -x "$scripts/Check Surge.sh" ] || fail 'menu wrapper is not executable'
cmp "$release/bin/check-surge" "$scripts/.check-surge"
hook="$scripts/Check on Save.scptd/Contents/Resources/Scripts/main.scpt"
[ -f "$hook" ] || fail 'save hook was not compiled'
/usr/bin/grep -F 'quoted form of (my checkerPath)' "$hook" >/dev/null
/usr/bin/grep -F '\"quotes\" \\ path/Library/' "$hook" >/dev/null
/usr/bin/grep -F '<array><string>document saved</string></array>' "$scripts/Check on Save.scptd/Contents/Info.plist" >/dev/null
printf 'unsaved contents\n' | "$scripts/Check Surge.sh" "path with 'quote" --language surge-module >"$temporary/actual"
{
    printf 'argument:<%s>\n' "path with 'quote" --language surge-module
    printf 'unsaved contents\n'
} >"$temporary/expected"
cmp "$temporary/expected" "$temporary/actual"
rm "$temporary/compiled"
expect_failure
assert_absent "$temporary/compiled"
cmp "$release/bin/check-surge" "$scripts/.check-surge"
assert_staging_empty

for target in syntax scripts; do
    for kind in file symlink; do
        test_home="$temporary/existing-$target-$kind"
        destinations
        if [ "$target" = syntax ]; then
            destination=$syntax
            other=$scripts
        else
            destination=$scripts
            other=$syntax
        fi
        mkdir -p "$(dirname -- "$destination")"
        if [ "$kind" = file ]; then
            printf 'Keep this manual installation.\n' >"$destination"
        else
            ln -s "$temporary/missing" "$destination"
        fi
        expect_failure
        assert_absent "$other"
        assert_absent "$temporary/compiled"
        if [ "$kind" = file ]; then
            [ "$(cat "$destination")" = 'Keep this manual installation.' ] || fail 'existing file changed'
        else
            [ -L "$destination" ] || fail 'dangling symlink was removed'
            [ "$(readlink "$destination")" = "$temporary/missing" ] || fail 'dangling symlink changed'
        fi
    done
done

test_home="$temporary/compile-failure"
compile_failure=true
expect_failure
assert_absent "$test_home"
assert_staging_empty
compile_failure=false
for target in syntax scripts; do
    test_home="$temporary/partial-$target"
    destinations
    mkdir -p "$(dirname -- "$syntax")" "$(dirname -- "$scripts")"
    printf 'manual syntax\n' >"$(dirname -- "$syntax")/Manual.cotsyntax"
    printf 'manual script\n' >"$(dirname -- "$scripts")/Manual.sh"
    if [ "$target" = syntax ]; then fail_copy=$syntax; else fail_copy=$scripts; fi
    expect_failure
    assert_absent "$syntax"
    assert_absent "$scripts"
    [ "$(cat "$(dirname -- "$syntax")/Manual.cotsyntax")" = 'manual syntax' ] || fail 'manual syntax changed'
    [ "$(cat "$(dirname -- "$scripts")/Manual.sh")" = 'manual script' ] || fail 'manual script changed'
    assert_staging_empty
done
printf 'Installer lifecycle checks passed.\n'
