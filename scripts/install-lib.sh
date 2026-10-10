#!/bin/sh

install_surge() (
    set -eu
    root=$1
    user_directory=$2
    app=/Applications/CotEditor.app
    if ! version=$(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist"); then
        printf 'Install CotEditor 7 or later at %s before installing.\n' "$app" >&2
        exit 1
    fi
    major=${version%%.*}
    case "$major" in
        '' | *[!0-9]*)
            printf 'Cannot determine the CotEditor version from %s.\n' "$app/Contents/Info.plist" >&2
            exit 1
            ;;
    esac
    if [ "$major" -lt 7 ]; then
        printf 'CotEditor 7 or later is required; found %s at %s.\n' "$version" "$app" >&2
        exit 1
    fi
    if [ ! -x "$root/bin/check-surge" ]; then
        printf 'The release binary is missing or not executable: %s/bin/check-surge\n' "$root" >&2
        exit 1
    fi

    syntax="$user_directory/Library/Containers/com.coteditor.CotEditor/Data/Library/Application Support/CotEditor/Syntaxes/Surge.cotsyntax"
    scripts="$user_directory/Library/Application Scripts/com.coteditor.CotEditor/Surge"
    for destination in "$syntax" "$scripts"; do
        if [ -e "$destination" ] || [ -L "$destination" ]; then
            printf 'Installation stopped: %s already exists.\nMove the existing Surge installation aside before installing again.\n' "$destination" >&2
            exit 1
        fi
    done

    temporary=
    created_syntax=false
    created_scripts=false
    complete=false
    # The EXIT trap invokes cleanup on every installation exit.
    # shellcheck disable=SC2329
    cleanup() {
        status=$?
        trap - 0 HUP INT TERM
        if [ "$complete" = false ]; then
            if [ "$created_scripts" = true ]; then rm -rf "$scripts"; fi
            if [ "$created_syntax" = true ]; then rm -rf "$syntax"; fi
        fi
        if [ -n "$temporary" ]; then rm -rf "$temporary"; fi
        exit "$status"
    }
    trap cleanup 0
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    umask 077
    temporary=$(mktemp -d "${TMPDIR:-/tmp}/coteditor-surge.XXXXXX")
    staging="$temporary/Surge"
    mkdir "$staging"
    cp "$root/bin/check-surge" "$staging/.check-surge"
    cp "$root/scripts/check-surge.sh" "$staging/Check Surge.sh"
    chmod 755 "$staging/.check-surge" "$staging/Check Surge.sh"
    {
        printf 'property checkerPath : "'
        printf '%s' "$scripts/.check-surge" | sed 's/\\/\\\\/g; s/"/\\"/g'
        printf '"\n'
        cat "$root/scripts/check-on-save.applescript"
    } >"$temporary/check-on-save.applescript"
    bundle="$staging/Check on Save.scptd"
    osacompile -o "$bundle" "$temporary/check-on-save.applescript"
    cat >"$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.aprilnea.coteditor-surge.check-on-save</string>
	<key>CFBundleName</key>
	<string>Surge Check on Save</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CotEditorHandlers</key>
	<array><string>document saved</string></array>
</dict>
</plist>
PLIST

    mkdir -p "$(dirname -- "$syntax")" "$(dirname -- "$scripts")"
    mkdir "$syntax"
    created_syntax=true
    cp -R "$root/Surge.cotsyntax/." "$syntax/"
    mkdir "$scripts"
    created_scripts=true
    cp -R "$staging/." "$scripts/"
    complete=true
    printf 'Installed: %s\nInstalled: %s\n' "$syntax" "$scripts"
    printf 'In Settings > Format, use Reload All Syntaxes from the actions menu.\n'
    printf 'Select the Surge syntax, then run Script > Surge > Check Surge.\n'
)
