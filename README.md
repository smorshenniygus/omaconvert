<p align="center">
  <img src="assets/kv.jpg" alt="OmaConvert: make it fit. Any file, any upload limit." width="820">
</p>

# OmaConvert

**Make any video or image fit an upload limit.** An Omarchy panel plugin: pick a file, type `gif 10mb`, press Enter. It finds the best quality that fits, measures the real file and never hands you an oversized result.

- **Every format, a real size check:** GIF, MP4, WebM, MKV, MOV, JPG, PNG, WebP, BMP, TIFF.
- **Recipes for the file you opened**, plus your own pinned ones (`jpg 150kb` for your site).
- **Batches:** select many files, one recipe for all of them.
- **Ctrl+V** a screenshot or a copied file; **trim** videos with a live preview.
- **Screen recordings over 10 MB** get a one-click “shrink it” notification.
- **Plays everywhere:** 8-bit H.264/VP9, HDR phone clips tone mapped to normal colors.
- **Local and private:** runs only `ffmpeg` on your machine, nothing is uploaded.

## Install

```bash
omarchy plugin add https://github.com/smorshenniygus/omaconvert --enable
```

Open it with `omarchy-shell shell toggle io.github.smorshenniygus.omaconvert`, or switch on **Hotkey** and **Open With** in the empty window.

Needs Omarchy 4, `ffmpeg`/`ffprobe` (already in Omarchy) and Python 3.10+. `gifsicle` and `wl-clipboard` are optional.

## Use

1. **Choose a file:** Enter, drop, Open With or **Ctrl+V**.
2. **Pick a recipe** or type a request in the `❯` line.
3. **Enter** — then open, copy or reveal the result.

| Type | Means |
|---|---|
| `gif`, `mp4`, `webm`, `jpg`, `png`, `webp` … | output format |
| `10mb`, `500kb` | size limit |
| `quick`, `quick high` | no size search, just quality |
| `frame`, `frames 10fps` | one still, or a PNG sequence |

The bar at the bottom of the window always shows the keys that work right now.

## Uninstall

```bash
omarchy plugin remove io.github.smorshenniygus.omaconvert
```

Switch off **Open With** and **Hotkey** in the window first if you turned them on.

---

**More:** [full guide](docs/guide.md) — keyboard, Omarchy integration, how Target Size works, files it writes, the JSON CLI and development. · [MIT](LICENSE)
