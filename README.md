# lofi

Lofi Girl, audio only, from the bar of an [Omarchy](https://omarchy.org) 4
desktop. A headphones-wearing silhouette sits in the bar; click her for the
list of streams currently live, pick one, and it plays through mpv with no
browser tab and no video decode. She takes the headphones off when nothing is
playing.

Lofi Girl has no radio stream — YouTube is the only live source — so the
script pulls `bestaudio` through yt-dlp and hands it to mpv. Play/pause and
next/previous are deliberately *not* here: `mpv-mpris` puts every mpv on
MPRIS, so Omarchy's stock `omarchy.media` widget and your keyboard's media
keys already handle them. This widget only chooses and stops.

Nothing cuts off hard. A small mpv script (`bin/fade.lua`) ramps the volume
over about a second on pause, resume, stop, and every new stream (a switch
fades out in 0.4 s, since silence follows anyway and it is on the way to the
next stream) —
including pause and resume from the media keys, since the script lives inside
the player rather than in the wrapper. The one cut it cannot soften is the
*end* of the old stream on MPRIS Next/Previous, because mpv drops the audio
before any script hears about it; the new stream still fades in after the
usual resolve gap.

Built for one desk. Shared in case it's useful on yours. No warranty, no
promises, no roadmap — but if it breaks in an interesting way, an issue is
welcome.

## Install

```sh
omarchy plugin add https://github.com/interslice-systems/lofi --enable
```

That clones the repo into `~/.config/omarchy/plugins/interslice.lofi` and
puts the widget in the bar. The widget finds its own script (`bin/lofi`)
relative to that folder, so nothing else is required.

Optional, if you want `lofi` as a command too:

```sh
ln -s ~/.config/omarchy/plugins/interslice.lofi/bin/lofi ~/.local/bin/lofi
```

### Dependencies

All from the official Arch repos:

| Package | Why |
|---|---|
| `mpv` | plays the stream |
| `socat` | one-line JSON to mpv's IPC socket, so `lofi stop` can ask for a fade instead of killing |
| `mpv-mpris` | puts mpv on MPRIS so the stock media widget and media keys work. Autoloads from `/etc/mpv/scripts/`; **do not** also add a `script=` line for it in `mpv.conf`, or the stream shows up as two players |
| `yt-dlp` | resolves the YouTube live stream to an audio URL |
| `python3` | JSON glue inside the script (already on every Omarchy install) |

Tested on Omarchy 4.0.3. The QML uses Omarchy's own shell components
(`BarWidget`, `BarIconButton`, `KeyboardPanel`, `CursorSurface`), so it will
not run on Omarchy 3 or on a bare Quickshell.

## Use

| Action | Result |
|---|---|
| Left click | list of live streams; click one to play, click the highlighted one to stop |
| Right click | stop, or resume the last-played stream |
| Middle click | stop |
| Media keys / `omarchy.media` arrows | next / previous stream — every live stream is loaded as mpv's playlist, so MPRIS Next and Previous step between them |

Keyboard: bind a key to `omarchy-shell shell toggle interslice.lofi` and the
same list opens with the cursor on the playing stream. Arrows or `j`/`k`
move, `Space`/`Enter` play the cursor row (or stop it if it's playing),
`Escape` closes. In `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + G", "Lofi Girl streams", "omarchy-shell shell toggle interslice.lofi")
```

## The script

`bin/lofi` is a plain bash script and works on its own:

```
lofi list          JSON array of currently-live streams [{id,title}], cached 1 h
lofi play <id>     start mpv with every live stream as its playlist, starting
                   at <id>; if one is already running, fade and switch in place
lofi stop          fade out and quit the running instance
lofi toggle        stop if running, else start the last-played stream
lofi status        JSON {"running":bool,"id":"...","title":"..."}
```

State lives in `$XDG_CACHE_HOME/lofi/` (stream list, last-played id) and
`$XDG_RUNTIME_DIR/lofi/` (pid, playlist). The stream list is discovered from
the channel's `/streams` tab, so new or retired streams need no code change;
if YouTube is unreachable the stale cache is served.

## Known behaviour

- YouTube expires the stream URL after some hours. If a stream stalls, pick it
  again from the list.
- If a YouTube tab is also open in a browser, `omarchy.media` will show two
  players; its right-click menu picks between them.
- Editing the QML through a symlinked plugin folder needs `omarchy restart
  shell` — the shell's file watcher does not follow the symlink, and a
  first-compile error sticks in Qt's component cache until a restart.

## License

MIT. See `LICENSE`.
