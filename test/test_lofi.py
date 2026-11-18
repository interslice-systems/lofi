"""bin/lofi against a fake mpv. Run: python3 -m unittest discover -s test

Nothing here touches the network, the real player, or the real state: the
script runs with its cache and runtime directories in a temp dir, a fresh
stream list seeded there, and `mpv` on PATH replaced by test/fake_mpv.py.
"""
import json
import os
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
LOFI = HERE.parent / "bin" / "lofi"
STREAMS = [{"id": "aaaaaaaaaaa", "title": "jazz lofi radio"},
           {"id": "bbbbbbbbbbb", "title": "synthwave radio"},
           {"id": "ccccccccccc", "title": "chill guitar radio"}]


class LofiScript(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="lofi-test-"))
        bindir = self.tmp / "bin"
        bindir.mkdir()
        # pgrep in bin/lofi looks for a command line starting "mpv ", so the
        # fake has to run under that name.
        shim = bindir / "mpv"
        shim.write_text('#!/usr/bin/env bash\nexec -a mpv python3 "$FAKE_MPV" "$@"\n')
        shim.chmod(0o755)
        fail = bindir / "yt-dlp"            # the cache is fresh; never reach out
        fail.write_text("#!/usr/bin/env bash\nexit 1\n")
        fail.chmod(0o755)
        cache = self.tmp / "cache" / "lofi"
        cache.mkdir(parents=True)
        (cache / "streams.json").write_text(json.dumps(STREAMS))
        self.run_dir = self.tmp / "run" / "lofi"
        self.env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}",
                        XDG_CACHE_HOME=str(self.tmp / "cache"),
                        XDG_RUNTIME_DIR=str(self.tmp / "run"),
                        FAKE_MPV=str(HERE / "fake_mpv.py"), FAKE_MPV_FADE="0.3")
        (self.tmp / "run").mkdir()

    def tearDown(self):
        for pid in self.players():
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        shutil.rmtree(self.tmp, ignore_errors=True)

    # ---- helpers -------------------------------------------------------
    def lofi(self, *args):
        return subprocess.run([str(LOFI), *args], env=self.env, text=True,
                              capture_output=True, timeout=30)

    def spawn(self, *args):
        return subprocess.Popen([str(LOFI), *args], env=self.env,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def status(self):
        return json.loads(self.lofi("status").stdout)

    def players(self):
        out = subprocess.run(
            ["pgrep", "-f", f"^mpv .*playlist={self.run_dir}/playlist.m3u"],
            text=True, capture_output=True).stdout.split()
        return [int(p) for p in out]

    def mpv(self, *command):
        """One command straight to the fake player, as MPRIS or a key would."""
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(2)
        s.connect(str(self.run_dir / "ipc"))
        s.sendall((json.dumps({"command": list(command), "request_id": 9}) + "\n").encode())
        s.recv(4096)
        s.close()

    def wait_gone(self, pid, secs=5):
        end = time.time() + secs
        while time.time() < end:
            try:
                os.kill(pid, 0)
            except OSError:
                return
            time.sleep(0.05)
        self.fail(f"player {pid} still alive")

    # ---- tests ---------------------------------------------------------
    def test_nothing_running(self):
        self.assertEqual(self.status(),
                         {"running": False, "playing": False, "id": "", "title": ""})

    def test_play_reports_a_playing_station(self):
        self.lofi("play", "bbbbbbbbbbb")
        self.assertEqual(self.status(), {"running": True, "playing": True,
                                         "id": "bbbbbbbbbbb", "title": "synthwave radio"})
        self.assertEqual(len(self.players()), 1)

    def test_a_paused_player_is_running_but_not_playing(self):
        # Headphones off, the door sensor, a media key: mpv pauses but lives.
        self.lofi("play", "aaaaaaaaaaa")
        self.mpv("set_property", "pause", True)
        st = self.status()
        self.assertTrue(st["running"])
        self.assertFalse(st["playing"])
        self.assertEqual(st["id"], "aaaaaaaaaaa")

    def test_toggle_resumes_a_paused_station_instead_of_stopping_it(self):
        self.lofi("play", "aaaaaaaaaaa")
        pid = self.players()[0]
        self.mpv("set_property", "pause", True)
        self.lofi("toggle")
        self.assertEqual(self.players(), [pid])          # same player, not a restart
        st = self.status()
        self.assertTrue(st["playing"])
        self.assertEqual(st["id"], "aaaaaaaaaaa")

    def test_toggle_stops_a_playing_station(self):
        self.lofi("play", "aaaaaaaaaaa")
        pid = self.players()[0]
        self.lofi("toggle")
        self.wait_gone(pid)
        self.assertEqual(self.status()["running"], False)

    def test_toggle_starts_the_last_played_station(self):
        self.lofi("play", "ccccccccccc")
        self.lofi("stop")
        self.lofi("toggle")
        self.assertEqual(self.status()["id"], "ccccccccccc")
        self.assertTrue(self.status()["playing"])

    def test_status_follows_a_station_change_made_inside_the_player(self):
        # The media keys step mpv's playlist without telling the script.
        self.lofi("play", "aaaaaaaaaaa")
        self.mpv("set_property", "playlist-pos", 2)
        st = self.status()
        self.assertEqual((st["id"], st["title"]), ("ccccccccccc", "chill guitar radio"))

    def test_overlapping_toggles_end_in_one_truthful_state(self):
        # Two quick pushes while playing: stop, then start. The second must
        # wait for the first instead of reading state mid-fade.
        self.lofi("play", "aaaaaaaaaaa")
        first = self.spawn("toggle")
        time.sleep(0.05)
        second = self.spawn("toggle")
        first.wait(timeout=30)
        second.wait(timeout=30)
        st = self.status()
        players = self.players()
        self.assertTrue(st["running"] and st["playing"], st)
        self.assertEqual(len(players), 1)
        self.assertEqual(int((self.run_dir / "pid").read_text()), players[0])

    def test_the_player_does_not_hold_the_lock(self):
        # mpv outlives the script that started it; if it inherited the lock,
        # every later command would hang.
        self.lofi("play", "aaaaaaaaaaa")
        started = time.time()
        self.lofi("stop")
        self.assertLess(time.time() - started, 8)
        self.assertEqual(self.players(), [])


if __name__ == "__main__":
    unittest.main()
