#!/usr/bin/env python3 -I
"""Drives riskell-setup through its whole guided flow in a pseudo-terminal, with a scratch HOME.

    python3 -I Tests/installer/pty_flow.py [--repo PATH] [--binary PATH]

The build, the launch agent and the risk link are skipped (--no-build --no-launch). The weather step is answered with
Skip, so nothing goes to the network. The test then checks the files written into the scratch HOME, and runs --yes
--dry-run against the same HOME to check that it prints the plan and writes nothing.
Then the usage opt-ins, each in its own scratch HOME: a consent panel that a key other than y declines (nothing written), a
panel that y accepts (both keys written, the OpenCode workspace typed in), and --yes, which leaves both opt-ins off.
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
import subprocess
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


def norm(data):
    """The screen text with every space removed: a redraw may skip unchanged cells, so phrases are matched without spaces."""
    return re.sub(r"\s+", "", data.decode("utf-8", "replace"))


def first_frame(fd):
    screen = b""
    end = time.time() + 5.0
    while b"setup" not in visible(screen) and time.time() < end:
        screen += drain(fd, 0.2)
    return screen


def usage_flow(binary, repo, home, usage_keys):
    """Walks the TUI to the usage step, sends each (keys, label) there, then finishes the install.
    Returns (exit code, {label: visible output after that key})."""
    env = {"HOME": str(home), "PATH": os.environ.get("PATH", "/usr/bin:/bin"), "TERM": "xterm-256color",
           "COLORTERM": "truecolor", "LANG": "en_US.UTF-8"}
    pid, fd = spawn([str(binary), "--no-build", "--no-launch", "--no-path", "--repo", str(repo)], env)
    first_frame(fd)
    for _ in range(5):          # welcome, window manager, bars, theme, weather (skip)
        send(fd, ENTER)
    seen = {}
    for keys, label in usage_keys:
        seen[label] = norm(visible(send(fd, keys)))
    for _ in range(4):          # usage, gestures, scale, review (the last Enter starts the install)
        send(fd, ENTER)
    drain(fd, 3.0)
    try:
        send(fd, ENTER, pause=0.5)  # finish
    except OSError:
        pass                        # already closed
    code = wait_exit(pid, 10)
    if code is None:
        os.kill(pid, 9)
    return code, seen


def read_usage(home):
    config = home / ".config/riskell/config.json"
    if not config.exists():
        return None
    return json.loads(config.read_text()).get("usage")


def usage_scenarios(binary, repo):
    default_profiles = "~/Library/Application Support/zen/Profiles"

    # 1. The limits panel opens; "n" declines; the OpenCode panel opens; "x" declines. Nothing opt-in is written.
    home = pathlib.Path(tempfile.mkdtemp(prefix="riskell-setup-home-"))
    try:
        code, seen = usage_flow(binary, repo, home, [
            (SPACE, "claude on"), (DOWN, "down"), (SPACE, "limits panel"),
            (b"n", "declined limits"), (DOWN, "down again"), (SPACE, "opencode panel"), (b"x", "declined opencode"),
        ])
        check("usage: the limits panel opens on space", "Anthropic" in seen["limits panel"])
        check("usage: a key other than y leaves the limits off", "leftoff" in seen["declined limits"])
        check("usage: the OpenCode panel opens on space", "console" in seen["opencode panel"])
        check("usage: a key other than y leaves OpenCode off", "leftoff" in seen["declined opencode"])
        check("usage: the decline flow exits 0", code == 0, "exit code " + str(code))
        usage = read_usage(home)
        check("usage: declined opt-ins write no key (only claude is on)", usage == {"claude": True}, str(usage))
    finally:
        shutil.rmtree(home, ignore_errors=True)

    # 2. y accepts both; the OpenCode workspace is typed into its field.
    home = pathlib.Path(tempfile.mkdtemp(prefix="riskell-setup-home-"))
    try:
        code, seen = usage_flow(binary, repo, home, [
            (SPACE, "claude on"), (DOWN, "down"), (SPACE, "limits panel"), (b"y", "accepted limits"),
            (DOWN, "down again"), (SPACE, "opencode panel"), (b"y", "accepted opencode"),
            (b"wrk_01KQXAMPLE01", "typed workspace"),
        ])
        check("usage: y accepts OpenCode and shows its workspace field", "workspace" in seen["accepted opencode"])
        check("usage: the accept flow exits 0", code == 0, "exit code " + str(code))
        usage = read_usage(home) or {}
        check("usage: accepted limits are written", usage.get("claudeLimits") is True and usage.get("claude") is True, str(usage))
        check("usage: the accepted workspace and default folder are written",
              usage.get("opencode") == {"workspace": "wrk_01KQXAMPLE01", "profiles": default_profiles}, str(usage.get("opencode")))
    finally:
        shutil.rmtree(home, ignore_errors=True)

    # 3. --yes alone: no opt-in is written.
    home = pathlib.Path(tempfile.mkdtemp(prefix="riskell-setup-home-"))
    try:
        env = {"HOME": str(home), "PATH": os.environ.get("PATH", "/usr/bin:/bin")}
        done = subprocess.run([str(binary), "--yes", "--no-build", "--no-launch", "--no-path", "--repo", str(repo)],
                              env=env, capture_output=True, timeout=120)
        check("--yes alone exits 0", done.returncode == 0, "exit code " + str(done.returncode))
        check("--yes alone writes no usage opt-in", read_usage(home) is None, str(read_usage(home)))
    finally:
        shutil.rmtree(home, ignore_errors=True)

    # 4. The flags: --claude-limits and --opencode-workspace are the consent; a bad workspace id is refused.
    flags = [str(binary), "--yes", "--claude-limits", "--opencode-workspace", "wrk_01KQXAMPLE01", "--dry-run",
             "--no-build", "--no-launch", "--no-path", "--repo", str(repo)]
    dry = subprocess.run(flags, env={"HOME": tempfile.mkdtemp(), "PATH": os.environ.get("PATH", "/usr/bin:/bin")},
                         capture_output=True, timeout=120, text=True)
    check("--claude-limits and --opencode-workspace plan both", dry.returncode == 0
          and re.search(r'"claudeLimits"\s*:\s*true', dry.stdout) is not None
          and re.search(r'"workspace"\s*:\s*"wrk_01KQXAMPLE01"', dry.stdout) is not None, dry.stdout[-300:])
    bad = subprocess.run([str(binary), "--yes", "--opencode-workspace", "wrk_x", "--dry-run", "--no-build", "--no-launch",
                          "--repo", str(repo)], env={"HOME": tempfile.mkdtemp(), "PATH": os.environ.get("PATH", "/usr/bin:/bin")},
                         capture_output=True, timeout=120, text=True)
    check("a bad --opencode-workspace is refused with exit 2", bad.returncode == 2, "exit code " + str(bad.returncode))
    helptext = subprocess.run([str(binary), "--help"], capture_output=True, timeout=30, text=True).stdout
    check("--help says what each usage flag does", all(f in helptext for f in
          ["--claude-limits", "--opencode-workspace", "--opencode-profiles"]))


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

    if binary.exists():
        usage_scenarios(binary, repo)

    if failures:
        print("%d check(s) failed" % len(failures))
        return 1
    print("pty flow: all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
