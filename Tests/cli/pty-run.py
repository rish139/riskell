"""Run a command with a pseudo-terminal for its stdin, stdout and stderr and copy what it wrote to our stdout.

`script(1)` needs a terminal on its own stdin, which a CI runner or a shell started from another tool does not have; this makes its own.
Usage: pty-run.py <command> [args...]. Exits with the command's status."""
import os
import pty
import select
import subprocess
import sys

master, slave = pty.openpty()
child = subprocess.Popen(sys.argv[1:], stdin=slave, stdout=slave, stderr=slave, close_fds=True)
os.close(slave)
chunks = []
while True:
    ready, _, _ = select.select([master], [], [], 0.2)
    if ready:
        try:
            data = os.read(master, 65536)
        except OSError:
            break
        if not data:
            break
        chunks.append(data)
    elif child.poll() is not None:
        break
child.wait()
sys.stdout.buffer.write(b"".join(chunks))
sys.exit(child.returncode)
