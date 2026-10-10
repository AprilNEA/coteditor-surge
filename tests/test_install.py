import importlib.util
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("installer", ROOT / "install.py")
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class InstallationTest(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
