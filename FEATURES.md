# RTSP Studio

RTSP Studio turns a folder of camera recordings into live RTSP feeds on one Linux host. You pick cameras, line them up to the same real-world moment, trim a start→end window, and publish (and optionally clip) them in lockstep.

The web UI is the control surface. **Start** and **Stop** always run on the host that is serving the UI — any browser on the LAN can drive it.

Default UI: `http://<host>:8787`  
Default RTSP: `rtsp://<host>:8554/<camera-stem>` over **TCP**

---

## Quick start

```bash
./install.sh
python3 ui.py
```

Open the printed URL, load a video folder, check the cameras to publish, set sync + trim, then **Start from here**.

`install.sh` puts MediaMTX v1.13.1 in `vendor/mediamtx` and checks for Python 3.10+, ffmpeg/ffprobe (libx264 + drawtext), and a monospace TTF for overlays.

This is a Linux app (WSL2 can work). There is no native Windows build.

---

## Folder → RTSP

Load a directory of videos (non-recursive). Each selected file becomes one MediaMTX path named from the file stem.

| Setting | Behavior |
| --- | --- |
| **Original** | Stream-copy when possible (keeps 4K H.264/H.265) |
| **720p** (UI default) / 1080p / 480p | Scale and encode libx264 |
| **Loop** | Repeat start→end (default) |
| **Seek all** | Restart the same feeds at the current trim without changing other settings |
| **Stop** | Tear down ffmpeg publishers and MediaMTX |

Supported files: `.mp4` `.mkv` `.mov` `.avi` `.m4v` `.webm` `.ts` `.mts`

RTSP is TCP-only in practice. 4K keyframes do not survive UDP RTP fragmentation — use TCP in the player (VLC extra option `:rtsp-tcp`).

Example:

```
rtsp://192.168.1.44:8554/SITE1-channel-2
```

---

## Multi-camera sync

Each tile is one camera: preview, per-camera scrub, ±1 frame, typed `HH:MM:SS.mmm`, **Set sync**, and **Use as ref**.

1. Scrub (or type) to the **same real-world event** on every camera and press **Set sync**.
2. Mark **one** camera as ref. The ref does **not** have to be selected as a published feed — it is only used for offset math.
3. Turn on **Align cameras using sync marks**.
4. Set the shared **Start** and **End** on the reference timeline. Other files shift by `(mark − ref mark)`.

Click a preview to open the lightbox with the same three markers: start, sync, and end.

Marks are stored in two places so they survive reloads and other browsers:

- `rtsp-sync.txt` in the video folder
- `.rtsp-state/ui.json` on the host

Partial saves from another tab **merge**; they no longer replace the whole set. **Clear sync marks** is the only way to wipe them.

---

## Trim, presets, and Play

One dual-handle bar sets start and end for every selected camera. Type stamps or nudge ±1 frame. The green fill is the loop window.

**Save start/end** stores a named preset in `rtsp-presets.json` in the video folder. Load it later to restore that window on every open UI.

**Play** is a JPEG preview loop of start→end on the main bar, each tile, and the lightbox. It does not start RTSP.

---

## Timestamp overlay

Optional burned-in clock: `dd-mm-yyyy hh:mm:ss.sss`.

| Control | Options |
| --- | --- |
| Corner | top-left, bottom-left, top-right, bottom-right |
| Size | small, medium, large, extra large |
| Color | white, yellow, red, green, blue |
| Wall clock | datetime at file `00:00:00` (host local time) |

The overlay is shown on previews immediately. On **Start** it is burned into the RTSP encode. Overlay forces libx264 even if resolution is Original.

---

## IR channels

**Publish IR channel per camera** adds a second RTSP path per selected file. Same start/end/sync as color. The look is a **simulation** from visible-light video, not true thermal data.

| Style | Look | Path |
| --- | --- | --- |
| Thermal | inferno heatmap | `…/<camera>_ir` |
| Night vision | green phosphor | `…/<camera>_ir` |

IR always encodes. If color is Original (4K copy), IR is 720p so the host is not encoding 4K heatmaps.

```
rtsp://192.168.1.44:8554/SITE1-channel-2
rtsp://192.168.1.44:8554/SITE1-channel-2_ir
```

---

## Clip export

**Create clip** writes a synchronized start→end cut of every **selected** camera.

Name or load a preset first. Output layout:

```
<video-folder>/<preset>/<camera>/<camera>.mp4
<video-folder>/<preset>/<camera>/<camera>_ir_thermal.mp4   # if IR is on
```

Example:

```
Santa-Clara-test-Videos/no-lights-round1/SITE1-channel-2/SITE1-channel-2.mp4
Santa-Clara-test-Videos/no-lights-round1/SITE1-channel-2/SITE1-channel-2_ir_thermal.mp4
```

Resolution follows the dropdown: Original copies the color cut; 720p/1080p/480p scales. IR clips always encode (720p when Original is selected).

The **Create clip** button turns grey when pressed, then fills green as each file encodes (`2 / 10`).

Clip folders are not mixed back into the source camera list. Loading a folder that only contains clips still works.

---

## Shared control

The UI listens on all interfaces (`UI_HOST` / `UI_PORT`, default `0.0.0.0:8787`).

- Folder, selection, trim, overlay, IR, and sync marks are a **shared session** across browsers.
- Start / Stop / Seek / Jitter / Create clip run **on the host**, not in the browser.
- While streams are running, most edit controls lock so two people cannot fight the live encode.

LAN hint in the UI: `http://<host-ip>:8787`

---

## Jitter

**Jitter** stops the live feeds for N seconds (0.1–120, default 2) and starts them again with the same session. Useful to desynchronize clients or recover a stuck player without changing trim or sync.

---

## Encoding rules

| Situation | Color RTSP | IR RTSP | Color clip | IR clip |
| --- | --- | --- | --- | --- |
| Original, no overlay | copy | 720p encode | copy | 720p encode |
| Original + overlay | encode | 720p encode | copy | 720p encode |
| 720p / 1080p / 480p | scale + encode | same height encode | scale + encode | same height encode |

Audio is omitted from RTSP (video-only). Clips keep video and copy/encode audio when present.

---

## Files the app writes

| Path | What |
| --- | --- |
| `.rtsp-state/` | PIDs, URLs, live UI session (`ui.json`) |
| `<folder>/rtsp-sync.txt` | Sync marks + ref |
| `<folder>/rtsp-presets.json` | Named start/end presets |
| `<folder>/<preset>/<camera>/` | Exported clips |

Source recordings are never overwritten.

---

## Command line

The UI calls `start.sh` / `stop.sh`. You can also publish without the browser:

```bash
./start.sh /path/to/videos --res 720 --offset 90 --end 180 \
  --only SITE1-channel-2.mp4 --only SITE1-channel-4.mp4 \
  --mark SITE1-channel-2.mp4=120.5 --mark SITE1-channel-4.mp4=123.1 \
  --ref SITE1-channel-2.mp4 \
  --overlay --overlay-pos top-right --overlay-size large --overlay-color yellow \
  --ir --ir-style thermal

./stop.sh
```

---

## Typical workflow

1. Load the folder of full recordings.
2. **Set sync** on each camera at the same event; **Use as ref** on one.
3. Turn **Align** on. Set start and end (or load a preset).
4. Optional: overlay, IR look, resolution.
5. **Start from here** — copy the LAN RTSP URLs into the player (TCP).
6. **Play** in the UI to preview the loop without touching RTSP.
7. **Create clip** into `<preset>/<camera>/` when the window is right.
8. **Jitter** or **Seek all** if a client needs a bump; **Stop** when done.

---

## License

RTSP Studio original source is [Apache License 2.0](LICENSE). Third-party runtimes (MediaMTX, FFmpeg, fonts) keep their own licenses; see [NOTICE](NOTICE).

Read [DISCLAIMER.md](DISCLAIMER.md) for responsible use: intended purpose, privacy, simulated IR, and operational limits.
