#!/usr/bin/env python3
"""Install Surge syntax and checking scripts for the current CotEditor user."""

import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
COTEDITOR_APP = Path("/Applications/CotEditor.app")


def applescript_string(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def install(home, python):
    if not COTEDITOR_APP.is_dir():
        raise FileNotFoundError(
            f"Install CotEditor 7 or later at {COTEDITOR_APP} before installing."
        )
    info_path = COTEDITOR_APP / "Contents/Info.plist"
    with info_path.open("rb") as info_file:
        version = plistlib.load(info_file).get("CFBundleShortVersionString")
    if not isinstance(version, str) or not version.split(".", 1)[0].isdecimal():
        raise ValueError(f"Cannot determine the CotEditor version from {info_path}.")
    if int(version.split(".", 1)[0]) < 7:
        raise ValueError(
            f"CotEditor 7 or later is required; found {version} at {COTEDITOR_APP}."
        )

    syntax = (
        home
        / "Library/Containers/com.coteditor.CotEditor/Data/Library/Application Support"
        / "CotEditor/Syntaxes/Surge.cotsyntax"
    )
    scripts = home / "Library/Application Scripts/com.coteditor.CotEditor/Surge"
    for destination in (syntax, scripts):
        if destination.exists() or destination.is_symlink():
            raise FileExistsError(
                f"Installation stopped: {destination} already exists. "
                "Move the existing Surge installation aside before installing again."
            )

    with tempfile.TemporaryDirectory(prefix="coteditor-surge-") as temporary:
        staging = Path(temporary) / "Surge"
        staging.mkdir()
        checker = staging / "Check Surge.py"
        source = (ROOT / "scripts/check-surge.py").read_text()
        checker.write_text(f"#!{python}\n" + source.split("\n", 1)[1])
        checker.chmod(0o755)

        hook_source = (ROOT / "scripts/check-on-save.applescript").read_text()
        hook_source = hook_source.replace("__PYTHON__", applescript_string(python))
        hook_source = hook_source.replace(
            "__CHECKER__", applescript_string(scripts / "Check Surge.py")
        )
        source_file = Path(temporary) / "check-on-save.applescript"
        source_file.write_text(hook_source)
        bundle = staging / "Check on Save.scptd"
        subprocess.run(
            ["/usr/bin/osacompile", "-o", str(bundle), str(source_file)], check=True
        )
        info_path = bundle / "Contents/Info.plist"
        info = {
            "CFBundleIdentifier": "com.aprilnea.coteditor-surge.check-on-save",
            "CFBundleName": "Surge Check on Save",
            "CFBundleShortVersionString": "0.1.0",
            "CotEditorHandlers": ["document saved"],
        }
        info_path.write_bytes(plistlib.dumps(info))

        created = []
        try:
            for source, destination in (
                (ROOT / "Surge.cotsyntax", syntax),
                (staging, scripts),
            ):
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.mkdir()
                created.append(destination)
                shutil.copytree(source, destination, dirs_exist_ok=True)
        except Exception:
            for destination in reversed(created):
                shutil.rmtree(destination)
            raise
    return syntax, scripts


if __name__ == "__main__":
    try:
        for installed in install(Path.home(), sys.executable):
            print(f"Installed: {installed}")
        print("In Settings > Format, use Reload All Syntaxes from the actions menu.")
        print("Select the Surge syntax, then run Script > Surge > Check Surge.")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
