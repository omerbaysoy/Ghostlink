"""PTY-backed terminal WebSocket — full bash in the browser."""

import os
import pty
import fcntl
import struct
import termios
import threading
import select
from flask import Blueprint
from flask_sock import Sock

bp = Blueprint("terminal", __name__)
_sock: Sock | None = None


def init_sock(sock: Sock):
    global _sock
    _sock = sock

    @sock.route("/ws/terminal")
    def terminal(ws):
        _handle_terminal(ws)


def _set_winsize(fd: int, rows: int, cols: int):
    winsize = struct.pack("HHHH", rows, cols, 0, 0)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, winsize)


def _handle_terminal(ws):
    master_fd, slave_fd = pty.openpty()

    pid = os.fork()
    if pid == 0:
        os.setsid()
        fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)
        for fd in (0, 1, 2):
            os.dup2(slave_fd, fd)
        os.close(master_fd)
        os.close(slave_fd)
        env = os.environ.copy()
        env["TERM"] = "xterm-256color"
        env["HOME"] = "/root"
        os.execve("/bin/bash", ["/bin/bash", "--login"], env)
    else:
        os.close(slave_fd)

        def _reader():
            try:
                while True:
                    r, _, _ = select.select([master_fd], [], [], 0.1)
                    if r:
                        data = os.read(master_fd, 4096)
                        if not data:
                            break
                        ws.send(data.decode("utf-8", errors="replace"))
            except Exception:
                pass

        t = threading.Thread(target=_reader, daemon=True)
        t.start()

        try:
            while True:
                msg = ws.receive(timeout=30)
                if msg is None:
                    break
                if isinstance(msg, str):
                    if msg.startswith("\x1b[8;"):
                        # resize: ESC[8;<rows>;<cols>t
                        parts = msg[4:].rstrip("t").split(";")
                        if len(parts) == 2:
                            _set_winsize(master_fd, int(parts[0]), int(parts[1]))
                    else:
                        os.write(master_fd, msg.encode())
                elif isinstance(msg, bytes):
                    os.write(master_fd, msg)
        except Exception:
            pass
        finally:
            try:
                os.kill(pid, 9)
                os.waitpid(pid, 0)
                os.close(master_fd)
            except Exception:
                pass
