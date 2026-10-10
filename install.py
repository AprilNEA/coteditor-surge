#!/usr/bin/env python3
"""Install Surge syntax and checking scripts for the current CotEditor user."""

import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def applescript_string(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def install(home, python):
    syntax = (
        home
        / "Library/Containers/com.coteditor.CotEditor/Data/Library/Application Support"
        / "CotEditor/Syntaxes/Surge.cotsyntax"
    )
    scripts = home / "Library/Application Scripts/com.coteditor.CotEditor/Surge"
    for destination in (syntax, scripts):
        if destination.exists():
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
            "CFBundleShortVersionString": "1.0.0",
            "CotEditorHandlers": ["document saved"],
        }
        info_path.write_bytes(plistlib.dumps(info))

        syntax.parent.mkdir(parents=True, exist_ok=True)
        scripts.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(ROOT / "Surge.cotsyntax", syntax)
        shutil.copytree(staging, scripts)
    return syntax, scripts


if __name__ == "__main__":
    try:
        for installed in install(Path.home(), sys.executable):
            print(f"Installed: {installed}")
        print("In Settings > Format, use Reload All Syntaxes from the actions menu.")
        print("Select the Surge syntax, then run Script > Surge > Check Surge.")
    except (OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
