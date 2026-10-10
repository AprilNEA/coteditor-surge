import importlib.util
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("installer", ROOT / "install.py")
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class InstallationTest(unittest.TestCase):
    def test_requires_coteditor_7_before_compilation_or_destination_writes(self):
        for version in (None, "6.9.9"):
            with (
                self.subTest(version=version),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                app = root / "CotEditor.app"
                home = root / "home"
                if version is not None:
                    (app / "Contents").mkdir(parents=True)
                    (app / "Contents/Info.plist").write_bytes(
                        plistlib.dumps({"CFBundleShortVersionString": version})
                    )
                with (
                    mock.patch.object(installer, "COTEDITOR_APP", app),
                    mock.patch.object(installer.subprocess, "run") as compile_hook,
                    mock.patch.object(
                        installer.tempfile, "TemporaryDirectory"
                    ) as stage,
                    self.assertRaisesRegex(
                        (FileNotFoundError, ValueError), "CotEditor 7 or later"
                    ),
                ):
                    installer.install(home, sys.executable)
                compile_hook.assert_not_called()
                stage.assert_not_called()
                self.assertFalse(home.exists())

    def test_installs_compiled_hook_and_refuses_to_overwrite_existing_files(self):
        with tempfile.TemporaryDirectory(prefix="surge install '") as directory:
            home = Path(directory)
            syntax, scripts = installer.install(home, sys.executable)
            self.assertTrue((syntax / "Info.json").is_file())
            self.assertTrue(
                (
                    scripts / "Check on Save.scptd/Contents/Resources/Scripts/main.scpt"
                ).is_file()
            )
            info = plistlib.loads(
                (scripts / "Check on Save.scptd/Contents/Info.plist").read_bytes()
            )
            self.assertEqual(info["CotEditorHandlers"], ["document saved"])
            checker = scripts / "Check Surge.py"
            self.assertEqual(checker.stat().st_mode & 0o777, 0o755)
            original = checker.read_bytes()
            with self.assertRaises(FileExistsError):
                installer.install(home, sys.executable)
            self.assertEqual(checker.read_bytes(), original)

    def test_partial_second_copy_removes_owned_targets_and_preserves_manual_files(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            syntax = (
                home
                / "Library/Containers/com.coteditor.CotEditor/Data/Library"
                / "Application Support/CotEditor/Syntaxes/Surge.cotsyntax"
            )
            scripts = home / "Library/Application Scripts/com.coteditor.CotEditor/Surge"
            sentinels = [
                syntax.parent / "Manual.cotsyntax",
                scripts.parent / "Manual.py",
            ]
            for sentinel in sentinels:
                sentinel.parent.mkdir(parents=True, exist_ok=True)
                sentinel.write_text("Keep this manual installation.\n")
            copytree = installer.shutil.copytree

            def fail_second_copy(source, destination, *args, **kwargs):
                if Path(destination) == scripts:
                    (destination / "partial.py").write_text("partial copy\n")
                    raise OSError("Synthetic second-copy failure")
                return copytree(source, destination, *args, **kwargs)

            with (
                mock.patch.object(
                    installer.shutil, "copytree", side_effect=fail_second_copy
                ),
                self.assertRaisesRegex(OSError, "Synthetic second-copy failure"),
            ):
                installer.install(home, sys.executable)
            self.assertFalse(syntax.exists())
            self.assertFalse(scripts.exists())
            for sentinel in sentinels:
                self.assertEqual(
                    sentinel.read_text(), "Keep this manual installation.\n"
                )


if __name__ == "__main__":
    unittest.main()
