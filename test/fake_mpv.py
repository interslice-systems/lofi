#!/usr/bin/env python3
"""A silent stand-in for mpv: just enough of the JSON IPC for bin/lofi's tests.

It keeps a pause flag and a playlist position, answers get_property/set_property,
and handles the two script messages bin/fade.lua provides (fade-quit takes
FAKE_MPV_FADE seconds, like the real fade)."""
import json
import os
import socket
import sys
import threading

FADE = float(os.environ.get("FAKE_MPV_FADE", "0.3"))


def arg(name, default=""):
    for a in sys.argv[1:]:
        if a.startswith("--" + name + "="):
            return a.split("=", 1)[1]
    return default


def load(path):
    try:
        with open(path) as f:
            return [l.strip() for l in f if l.strip() and not l.startswith("#")]
    except OSError:
        return []


state = {"pause": False, "list": load(arg("playlist")),
         "pos": int(arg("playlist-start", "0") or 0)}


def prop(name):
    if name == "pause":
        return state["pause"]
    if name == "idle-active":
        return not state["list"]
    if name == "path" and state["list"]:
        return state["list"][state["pos"] % len(state["list"])]
    return None


def handle(conn):
    buf = b""
    with conn:
        while True:
            try:
                chunk = conn.recv(65536)
            except OSError:
                return
            if not chunk:
                return
            buf += chunk
            *lines, buf = buf.split(b"\n")
            for line in lines:
                try:
                    m = json.loads(line)
                except ValueError:
                    continue
                c = m.get("command", [])
                out = {"request_id": m.get("request_id", 0), "error": "success"}
                if c[:1] == ["get_property"]:
                    v = prop(c[1])
                    if v is None:
                        out["error"] = "property unavailable"
                    else:
                        out["data"] = v
                elif c[:2] == ["set_property", "pause"]:
                    state["pause"] = bool(c[2])
                elif c[:2] == ["set_property", "playlist-pos"]:
                    state["pos"] = int(c[2])
                elif c[:2] == ["script-message", "fade-quit"]:
                    threading.Timer(FADE, lambda: os._exit(0)).start()
                elif c[:2] == ["script-message", "fade-play"]:
                    state.update(list=load(c[2]), pos=int(c[3]), pause=False)
                elif c[:1] == ["quit"]:
                    os._exit(0)
                try:
                    conn.sendall((json.dumps(out) + "\n").encode())
                except OSError:
                    return


path = arg("input-ipc-server")
try:
    os.unlink(path)
except OSError:
    pass
srv = socket.socket(socket.AF_UNIX)
srv.bind(path)
srv.listen(8)
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
