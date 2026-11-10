#!/usr/bin/env python3
"""Host-side helpers for tools/test-net.sh (the -N nat tests), on 127.0.0.1.

  net-echo.py serve TCPPORT UDPPORT     a TCP echo server and a UDP echo server
                                        (until killed)
  net-echo.py client PORT TEXT [SECS]   connect to 127.0.0.1:PORT (again and again
                                        until something comes back, for SECS
                                        seconds), send TEXT and a newline, print what
                                        comes back until the peer closes
"""
import socket
import sys
import threading
import time


def tcp_conn(c):
    with c:
        while True:
            d = c.recv(65536)
            if not d:
                return
            c.sendall(d)


def serve(tport, uport):
    t = socket.socket()
    t.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    t.bind(("127.0.0.1", tport))
    t.listen(16)
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.bind(("127.0.0.1", uport))

    def udp():
        while True:
            d, a = u.recvfrom(65536)
            u.sendto(d, a)

    threading.Thread(target=udp, daemon=True).start()
    while True:
        c, _ = t.accept()
        threading.Thread(target=tcp_conn, args=(c,), daemon=True).start()


def client(port, text, secs):
    end = time.time() + secs
    while time.time() < end:
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=5)
            s.sendall(text.encode() + b"\n")
            got = b""
            while True:
                d = s.recv(65536)
                if not d:
                    break
                got += d
                if got.endswith(b"\n"):
                    break
            s.close()
            if got:
                sys.stdout.write(got.decode(errors="replace"))
                return 0
        except OSError:
            pass
        time.sleep(0.5)
    return 1


if __name__ == "__main__":
    if sys.argv[1] == "serve":
        serve(int(sys.argv[2]), int(sys.argv[3]))
    else:
        sys.exit(client(int(sys.argv[2]), sys.argv[3], float(sys.argv[4]) if len(sys.argv) > 4 else 60))
