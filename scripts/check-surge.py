#!/usr/bin/env python3
# %%%{CotEditorXInput=AllText}%%%
# %%%{CotEditorXOutput=Discard}%%%

"""Send the current CotEditor document to Surge's offline language server."""

import argparse
import json
import os
import re
import select
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SURGE_CLI = "/Applications/Surge.app/Contents/Applications/surge-cli"
TIMEOUT = 10


def language_for(text, path):
    suffix = Path(path).suffix.lower() if path else ""
    if suffix == ".sgmodule":
        return "surge-module"
    if suffix in {".sgruleset", ".list"}:
        return "surge-ruleset"
    if suffix == ".dconf":
        return "surge"
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("#!name="):
            return "surge-module"
        if line.startswith("["):
            return "surge"
        if not line or line.startswith(("#", ";", "//")):
            continue
        if re.match(r"[A-Z][A-Z0-9-]*\s*,", line):
            return "surge-ruleset"
        break
    return "surge"


class Connection:
    def __init__(self, process, deadline):
        self.process = process
        self.deadline = deadline
        self.buffer = b""

    def send(self, message):
        body = json.dumps({"jsonrpc": "2.0", **message}).encode("utf-8")
        self.process.stdin.write(
            f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body
        )
        self.process.stdin.flush()

    def receive(self):
        while True:
            header, separator, body = self.buffer.partition(b"\r\n\r\n")
            if separator:
                headers = dict(line.split(b":", 1) for line in header.split(b"\r\n"))
                length = int(headers[b"Content-Length"])
                if length < 0:
                    raise ValueError(
                        "The language server returned a negative frame length."
                    )
                if len(body) >= length:
                    self.buffer = body[length:]
                    return json.loads(body[:length])
            remaining = self.deadline - time.monotonic()
            if (
                remaining <= 0
                or not select.select([self.process.stdout], [], [], remaining)[0]
            ):
                raise TimeoutError(
                    f"Surge did not complete the check within {TIMEOUT}s."
                )
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError(
                    "Surge closed the language server before completion."
                )
            self.buffer += chunk

    def wait(self, predicate):
        while True:
            message = self.receive()
            if "error" in message:
                raise RuntimeError(f"Surge LSP: {message['error']['message']}")
            if "method" in message and "id" in message:
                self.send(
                    {
                        "id": message["id"],
                        "error": {"code": -32601, "message": "Method not supported"},
                    }
                )
            elif predicate(message):
                return message


def check_document(text, path=None, language=None):
    language = language or language_for(text, path)
    uri = Path(path).absolute().as_uri() if path else "untitled:Surge"
    deadline = time.monotonic() + TIMEOUT
    with tempfile.TemporaryFile() as errors:
        with subprocess.Popen(
            [SURGE_CLI, "lsp", "--stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=errors,
        ) as process:
            connection = Connection(process, deadline)
            try:
                connection.send(
                    {
                        "id": 1,
                        "method": "initialize",
                        "params": {
                            "processId": os.getpid(),
                            "capabilities": {},
                            "rootUri": Path(path).absolute().parent.as_uri()
                            if path
                            else None,
                        },
                    }
                )
                connection.wait(lambda message: message.get("id") == 1)
                connection.send({"method": "initialized", "params": {}})
                # shortcut: One buffer only; add sessions for cross-file editing.
                connection.send(
                    {
                        "method": "textDocument/didOpen",
                        "params": {
                            "textDocument": {
                                "uri": uri,
                                "languageId": language,
                                "version": 1,
                                "text": text,
                            }
                        },
                    }
                )
                diagnostics = connection.wait(
                    lambda message: (
                        message.get("method") == "textDocument/publishDiagnostics"
                        and message["params"]["uri"] == uri
                        and message["params"].get("version", 1) == 1
                    )
                )["params"]["diagnostics"]
                connection.send({"id": 2, "method": "shutdown"})
                connection.wait(lambda message: message.get("id") == 2)
                connection.send({"method": "exit"})
                process.wait(timeout=max(0, deadline - time.monotonic()))
                if process.returncode:
                    raise RuntimeError(
                        f"Surge exited with status {process.returncode}."
                    )
                return diagnostics
            except (
                OSError,
                ValueError,
                RuntimeError,
                subprocess.TimeoutExpired,
            ) as error:
                errors.seek(0)
                detail = errors.read().decode("utf-8", errors="replace").strip()
                if detail:
                    raise RuntimeError(f"{error}\n{detail}") from error
                raise
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait()


def report(diagnostics, path):
    name = path or "Untitled"
    if not diagnostics:
        return f"{name}: Surge reported no diagnostics."
    severities = {1: "error", 2: "warning", 3: "information", 4: "hint"}
    lines = []
    for diagnostic in diagnostics:
        start = diagnostic["range"]["start"]
        severity = severities.get(diagnostic.get("severity"), "diagnostic")
        lines.append(
            f"{name}:{start['line'] + 1}:{start['character'] + 1}: "
            f"{severity}: {diagnostic['message']}"
        )
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", nargs="?")
    parser.add_argument("--saved", action="store_true", help="Read the saved file.")
    parser.add_argument(
        "--language", choices=["surge", "surge-module", "surge-ruleset"]
    )
    arguments = parser.parse_args()
    if arguments.saved and not arguments.path:
        parser.error("--saved requires a file path")
    try:
        text = (
            Path(arguments.path).read_text(encoding="utf-8-sig")
            if arguments.saved
            else sys.stdin.read().removeprefix("\ufeff")
        )
        diagnostics = check_document(text, arguments.path, arguments.language)
        print(report(diagnostics, arguments.path), file=sys.stderr)
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Surge check failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
