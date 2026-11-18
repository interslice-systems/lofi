"""Static checks on Lofi.qml. The shell is long-lived and unsandboxed, and the
widget draws text that came from YouTube (stream titles) and from another
program (`macropad status`), so nothing may be rendered as rich text.

Run: python3 -m unittest discover -s test
"""
import re
import unittest
from pathlib import Path

QML = (Path(__file__).resolve().parent.parent / "Lofi.qml").read_text()


def blocks(kind):
    """The body of every `<kind> { ... }` element, by brace matching."""
    out = []
    for m in re.finditer(r"(?<![\w.])%s \{" % kind, QML):
        depth, i = 1, m.end()
        while depth:
            depth += {"{": 1, "}": -1}.get(QML[i], 0)
            i += 1
        out.append(QML[m.end():i - 1])
    return out


class Widget(unittest.TestCase):
    def test_every_text_element_is_plain_text(self):
        texts = blocks("Text")
        self.assertGreaterEqual(len(texts), 8)
        for body in texts:
            self.assertIn("textFormat: Text.PlainText", body, body[:120])

    def test_no_literal_private_use_glyphs(self):
        # Icon-font glyphs are written as \uXXXX escapes: a literal one is
        # invisible in most editors and easy to corrupt.
        self.assertFalse(re.search("[\ue000-\uf8ff]", QML))

    def test_the_pad_is_only_asked_while_the_list_is_open(self):
        timer = next(b for b in blocks("Timer") if "padProc" in b)
        self.assertIn("running: root.popupOpen && root.pad !== null", timer)

    def test_what_the_pad_says_is_bounded_before_it_is_used(self):
        proc = next(b for b in blocks("Process") if '"macropad", "status"' in b)
        self.assertIn("s.keys.slice(0, 12)", proc)
        self.assertIn("/^[a-z]{1,16}$/", proc)       # a name goes back as an argument
        self.assertIn("padViz.indexOf(name) < 0", QML)


if __name__ == "__main__":
    unittest.main()
