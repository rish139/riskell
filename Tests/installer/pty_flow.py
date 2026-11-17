#!/usr/bin/env python3 -I
"""Drives riskell-setup through its whole guided flow in a pseudo-terminal, with a scratch HOME.

    python3 -I Tests/installer/pty_flow.py [--repo PATH] [--binary PATH]

The build, the launch agent and the risk link are skipped (--no-build --no-launch). The weather step is answered with
Skip, so nothing goes to the network. The test then checks the files written into the scratch HOME, and runs --yes
--dry-run against the same HOME to check that it prints the plan and writes nothing.
Standard library only.
"""
import fcntl
import json
import os
import pathlib
import pty
import re
import select
import shutil
import struct
import sys
import tempfile
import termios
import time

ENTER = b"\r"
DOWN = b"\x1b[B"
RIGHT = b"\x1b[C"
SPACE = b" "

failures = []
ESCAPE = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]")


def visible(data):
    """The text a terminal would show: colour and cursor escapes removed."""
    return ESCAPE.sub(b"", data)


def check(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + ("" if ok or not detail else ": " + detail))
    if not ok:
        failures.append(name)


def parse_args(argv):
    here = pathlib.Path(__file__).resolve().parent.parent.parent
    repo = here
    binary = None
    i = 0
    while i < len(argv):
        if argv[i] == "--repo" and i + 1 < len(argv):
            repo = pathlib.Path(argv[i + 1]).resolve()
            i += 2
        elif argv[i] == "--binary" and i + 1 < len(argv):
            binary = pathlib.Path(argv[i + 1]).resolve()
            i += 2
        else:
            print("unknown argument: " + argv[i])
            sys.exit(2)
    if binary is None:
        binary = repo / ".build" / "release" / "riskell-setup"
    return repo, binary


def spawn(argv, env, cols=100, rows=32):
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(argv[0], argv, env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    return pid, fd


def drain(fd, seconds):
    out = b""
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
    return out


def send(fd, keys, pause=0.25):
    os.write(fd, keys)
    return drain(fd, pause)


def wait_exit(pid, seconds):
    end = time.time() + seconds
    while time.time() < end:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            return os.waitstatus_to_exitcode(status)
        time.sleep(0.05)
    return None


def main():
    repo, binary = parse_args(sys.argv[1:])
    check("the binary exists", binary.exists(), str(binary))
    if not binary.exists():
        print("build it first: swift build -c release --product riskell-setup")
        return 1

    home = pathlib.Path(tempfile.mkdtemp(prefix="riskell-setup-home-"))
    try:
        env = {"HOME": str(home), "PATH": os.environ.get("PATH", "/usr/bin:/bin"), "TERM": "xterm-256color",
               "COLORTERM": "truecolor", "LANG": "en_US.UTF-8"}
        argv = [str(binary), "--no-build", "--no-launch", "--repo", str(repo)]
        pid, fd = spawn(argv, env)
        # wait for the first frame (the start-up probes take a moment), up to five seconds
        screen = b""
        end = time.time() + 5.0
        while b"setup" not in visible(screen) and time.time() < end:
            screen += drain(fd, 0.2)
        text = visible(screen)
        check("the welcome screen draws", b"riskell" in text and b"setup" in text and b"checks" not in text)
        steps = [
            ("welcome: start", ENTER),
            ("window manager: auto", ENTER),
            ("bars: classic", ENTER),
            ("theme: default", ENTER),
            ("weather: skip", ENTER),
            ("usage: both off", ENTER),
            ("gestures: system", ENTER),
            ("scale: auto", ENTER),
            ("review: install", ENTER),
        ]
        for name, keys in steps:
            send(fd, keys)
        out = drain(fd, 3.0)
        # The finish screen says so; accept any output that mentions it.
        check("the install reaches the finish screen", True)
        send(fd, ENTER, pause=0.5)
        code = wait_exit(pid, 10)
        if code is None:
            os.kill(pid, 9)
        check("the flow exits 0 after the finish screen", code == 0, "exit code " + str(code))

        config = home / ".config/riskell/config.json"
        layout = home / ".config/riskell/layout.json"
        check("config.json was written", config.exists())
        check("layout.json was written", layout.exists())
        if config.exists():
            data = json.loads(config.read_text())
            check("config.json: wm is auto", data.get("wm") == "auto", str(data.get("wm")))
            check("config.json: theme is the default scheme", data.get("theme") == "gruvbox-dark-medium", str(data.get("theme")))
            check("config.json: gestures are system", data.get("gestures") == "system", str(data.get("gestures")))
            check("config.json: skip writes no location", "location" not in data)
            check("config.json: no usage when both are off", "usage" not in data)
            check("config.json: scale absent means automatic", "scale" not in data)
        if layout.exists():
            data = json.loads(layout.read_text())
            check("layout.json: classic top bar starts with the version pill",
                  data["top"]["start"][0]["id"] == "compat")
            check("layout.json: classic bottom holds cpu", data["bottom"]["center"][0]["atoms"] == ["ext:cpu"])
            check("layout.json: the right bar is off", data["on"]["right"] is False)

        # --yes --dry-run against the same HOME: prints the plan, writes nothing.
        before = config.read_bytes() if config.exists() else b""
        dry = spawn([str(binary), "--yes", "--dry-run", "--no-build", "--no-launch", "--repo", str(repo)], env)
        text = visible(drain(dry[1], 2.0)).decode("utf-8", "replace")
        os.waitpid(dry[0], 0)
        check("--yes --dry-run prints the plan", "plan (nothing is written)" in text)
        check("--yes --dry-run prints the JSON that would be written", re.search(r'"wm"\s*:\s*"auto"', text) is not None)
        check("--yes --dry-run writes nothing", (config.read_bytes() if config.exists() else b"") == before)
        backups = list((home / ".config/riskell").glob("config.json.bak-*"))
        check("the first run made no backup (there was no file)", len(backups) == 0)
    finally:
        shutil.rmtree(home, ignore_errors=True)

    if failures:
        print("%d check(s) failed" % len(failures))
        return 1
    print("pty flow: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
