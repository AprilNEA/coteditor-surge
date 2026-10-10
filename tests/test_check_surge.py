import importlib.util
import io
import json
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "check-surge.py"
SPEC = importlib.util.spec_from_file_location("check_surge", SCRIPT)
surge = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(surge)


def frame(message):
    body = json.dumps(message, ensure_ascii=False).encode("utf-8")
    return f"Content-Length: {len(body)}\r\n\r\n".encode() + body


def fake_process(returncode=None):
    process = mock.MagicMock()
    process.__enter__.return_value = process
    process.stdin = io.BytesIO()
    process.returncode = returncode
    process.poll.return_value = returncode
    return process


class ProtocolTests(unittest.TestCase):
    def test_receive_fragmented_unicode_and_coalesced_frames(self):
        first = {"message": "例子🐱"}
        second = {"id": 2, "result": None}
        stream = frame(first) + frame(second)
        split = stream.index("🐱".encode()) + 1
        process = fake_process()
        connection = surge.Connection(process, time.monotonic() + 1)
        with (
            mock.patch.object(
                surge.select, "select", return_value=([process.stdout], [], [])
            ),
            mock.patch.object(
                surge.os,
                "read",
                side_effect=[stream[:7], stream[7:split], stream[split:]],
            ) as read,
        ):
            self.assertEqual(connection.receive(), first)
            self.assertEqual(connection.receive(), second)
        self.assertEqual(read.call_count, 3)

    def test_send_uses_encoded_body_length(self):
        process = fake_process()
        connection = surge.Connection(process, time.monotonic() + 1)
        connection.send({"method": "probe", "params": {"text": "例子🐱"}})
        header, body = process.stdin.getvalue().split(b"\r\n\r\n", 1)
        self.assertEqual(int(header.split(b":")[1]), len(body))
        self.assertEqual(json.loads(body)["params"]["text"], "例子🐱")

    def test_diagnostics_must_match_uri_and_version(self):
        process = fake_process(returncode=0)
        wanted = [{"message": "current diagnostic"}]

        def diagnostics(uri, version, values):
            return {
                "method": "textDocument/publishDiagnostics",
                "params": {"uri": uri, "version": version, "diagnostics": values},
            }

        messages = [
            {"id": 1, "result": {}},
            {"id": 9, "method": "workspace/configuration", "params": {}},
            diagnostics("untitled:Other", 1, [{"message": "wrong document"}]),
            diagnostics("untitled:Surge", 0, [{"message": "stale diagnostic"}]),
            diagnostics("untitled:Surge", 1, wanted),
            {"id": 2, "result": None},
        ]
        with (
            mock.patch.object(surge.subprocess, "Popen", return_value=process),
            mock.patch.object(surge.Connection, "receive", side_effect=messages),
        ):
            self.assertEqual(surge.check_document("[Rule]\nFINAL,DIRECT\n"), wanted)
        self.assertIn(b"Method not supported", process.stdin.getvalue())
        process.kill.assert_not_called()

    def test_timeout_and_early_eof_kill_and_reap_server(self):
        for failure in ("timeout", "eof"):
            with self.subTest(failure=failure):
                process = fake_process()
                ready = [] if failure == "timeout" else [process.stdout]
                error = TimeoutError if failure == "timeout" else RuntimeError
                with (
                    mock.patch.object(surge.subprocess, "Popen", return_value=process),
                    mock.patch.object(
                        surge.select, "select", return_value=(ready, [], [])
                    ),
                    mock.patch.object(surge.os, "read", return_value=b""),
                    self.assertRaises(error),
                ):
                    surge.check_document("[Rule]\nFINAL,DIRECT\n")
                process.kill.assert_called_once_with()
                process.wait.assert_called_once_with()


class InputTests(unittest.TestCase):
    def test_detects_language_from_extension_and_unsaved_text(self):
        cases = [
            ("", "test.sgmodule", "surge-module"),
            ("", "test.LIST", "surge-ruleset"),
            ("", "test.sgruleset", "surge-ruleset"),
            ("DOMAIN,example.com,DIRECT", "test.dconf", "surge"),
            ("# comment\n#!name=Example\n[Rule]\n", None, "surge-module"),
            ("# comment\nDOMAIN,example.com\n", None, "surge-ruleset"),
            ("[Rule]\nFINAL,DIRECT\n", None, "surge"),
            ("", None, "surge"),
        ]
        for text, path, language in cases:
            with self.subTest(path=path, text=text):
                self.assertEqual(surge.language_for(text, path), language)

    def test_invalid_utf8_saved_file_fails_without_starting_server(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.conf"
            path.write_bytes(b"[Rule]\n\xff\n")
            output = io.StringIO()
            with (
                mock.patch.object(
                    surge.sys, "argv", [str(SCRIPT), "--saved", str(path)]
                ),
                mock.patch.object(surge.sys, "stderr", output),
                mock.patch.object(surge, "check_document") as check,
            ):
                self.assertEqual(surge.main(), 1)
            check.assert_not_called()
            self.assertIn("Surge check failed:", output.getvalue())
            self.assertEqual(path.read_bytes(), b"[Rule]\n\xff\n")


@unittest.skipUnless(Path(surge.SURGE_CLI).is_file(), "Surge CLI is not installed")
class LiveSurgeTests(unittest.TestCase):
    def test_all_languages_accept_valid_and_diagnose_invalid_untitled_text(self):
        cases = [
            ("surge", "[Rule]\nFINAL,DIRECT\n", "[Rule]\nFINAL,Missing\n", 1),
            (
                "surge-module",
                "#!name=Probe\n[General]\nloglevel = notify\n",
                "#!name=Probe\n[Rule]\nBOGUS,example.com\n",
                2,
            ),
            (
                "surge-ruleset",
                "DOMAIN,example.com\n",
                "# 中文 🐱\nBOGUS,例子🐱.com\n",
                1,
            ),
        ]
        for language, valid, invalid, line in cases:
            with self.subTest(language=language):
                self.assertEqual(surge.check_document(valid, language=language), [])
                diagnostics = surge.check_document(invalid, language=language)
                self.assertTrue(diagnostics)
                self.assertEqual(diagnostics[0]["severity"], 1)
                self.assertEqual(diagnostics[0]["range"]["start"]["line"], line)
                if language == "surge-ruleset":
                    self.assertEqual(diagnostics[0]["range"]["end"]["character"], 14)

    def test_stdin_uses_unsaved_text_and_preserves_saved_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Surge.conf"
            saved = b"[Rule]\nFINAL,Missing\n"
            path.write_bytes(saved)
            for use_saved in (False, True):
                with self.subTest(use_saved=use_saved):
                    arguments = [str(SCRIPT), str(path)]
                    if use_saved:
                        arguments.append("--saved")
                    output = io.StringIO()
                    with (
                        mock.patch.object(surge.sys, "argv", arguments),
                        mock.patch.object(
                            surge.sys,
                            "stdin",
                            io.StringIO("\ufeff[Rule]\nFINAL,DIRECT\n"),
                        ),
                        mock.patch.object(surge.sys, "stderr", output),
                    ):
                        self.assertEqual(surge.main(), 0)
                    if use_saved:
                        self.assertIn(f"{path}:2:1: error:", output.getvalue())
                        self.assertIn("Missing", output.getvalue())
                    else:
                        self.assertIn("reported no diagnostics", output.getvalue())
                    self.assertEqual(path.read_bytes(), saved)


if __name__ == "__main__":
    unittest.main()
