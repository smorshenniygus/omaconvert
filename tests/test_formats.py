"""DEV-01: format registry, --capabilities and early missing-encoder errors.

A stub `ffmpeg` placed first on PATH answers -encoders/-muxers/-filters with
a reduced table (no libwebp, no libopus) and forwards everything else to the
real FFmpeg, imitating a minimal distribution build.
"""
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import unittest

from lib import formats, launcher

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "bin" / "omaconvert"
FFMPEG = shutil.which("ffmpeg")
HAVE_TOOLS = bool(FFMPEG and shutil.which("ffprobe"))

ENCODERS = """Encoders:
 V..... = Video
 A..... = Audio
 ------
 V....D gif                  GIF (Graphics Interchange Format)
 V....D libx264              libx264 H.264 / AVC
 VFS..D mjpeg                MJPEG (Motion JPEG)
 VF...D png                  PNG (Portable Network Graphics) image
 VF...D tiff                 TIFF image
 V....D bmp                  BMP (Windows and OS/2 bitmap)
 V....D libvpx-vp9           libvpx VP9 (codec vp9)
 A....D aac                  AAC (Advanced Audio Coding)
"""
# FFmpeg 7.0+ shape: a device column and a "---" separator.
MUXERS = """Formats:
 D.. = Demuxing supported
 .E. = Muxing supported
 ..d = Is a device
 ---
  Ed alsa            ALSA audio output
 D   aa              Audible AA format files
  E  gif             CompuServe Graphics Interchange Format (GIF)
  E  image2          image2 sequence
  E  matroska        Matroska
  E  mov             QuickTime / MOV
  E  mp4             MP4 (MPEG-4 Part 14)
  E  webm            WebM
  E  webp            WebP
"""
# FFmpeg 6.x shape: two flag columns and a "--" separator.
MUXERS_6 = """File formats:
 D. = Demuxing supported
 .E = Muxing supported
 --
  E gif             CompuServe Graphics Interchange Format (GIF)
  E image2          image2 sequence
  E mp4             MP4 (MPEG-4 Part 14)
 D  mpegts          MPEG-TS (MPEG-2 Transport Stream)
"""
# FFmpeg 7.0 to 8.0 shape: no separator between the legend and the rows.
FILTERS = """Filters:
  T.. = Timeline support
  .S. = Slice threading
  ..C = Command support
  A = Audio input/output
  V = Video input/output
  N = Dynamic number and/or type of input/output
  | = Source or sink filter
 ... palettegen        V->V       Find the optimal palette for a given stream.
 ... paletteuse        VV->V      Use a palette to downsample an input video stream.
 ..C scale             V->V       Scale the input video size and/or convert the image format.
"""
# FFmpeg 8.1+ shape: a "------" separator.
FILTERS_81 = """Filters:
  T.. = Timeline support
  .S. = Slice threading
  A = Audio input/output
  V = Video input/output
  N = Dynamic number and/or type of input/output
  | = Source or sink filter
  ------
 ... palettegen        V->V       Find the optimal palette for a given stream.
 .S. tonemap           V->V       Conversion to/from different dynamic ranges.
 .SC zscale            V->V       Apply resizing, colorspace and bit depth conversion.
"""


class ParseTests(unittest.TestCase):
    def tools(self):
        return formats.Toolbox(frozenset(formats._table(ENCODERS)),
                               frozenset(formats._flagged_muxers(MUXERS)),
                               frozenset(formats._table(FILTERS)))

    def test_tables_skip_legend(self):
        tools = self.tools()
        self.assertIn("libx264", tools.encoders)
        self.assertNotIn("V.....", tools.encoders)
        self.assertNotIn("=", tools.encoders)
        self.assertEqual(tools.muxers, {"alsa", "gif", "image2", "matroska", "mov", "mp4", "webm", "webp"})
        self.assertEqual(tools.filters, {"palettegen", "paletteuse", "scale"})

    def test_tables_of_every_ffmpeg_generation(self):
        # Separators differ between versions; rows must be found in each.
        self.assertEqual(formats._flagged_muxers(MUXERS_6), {"gif", "image2", "mp4"})
        self.assertEqual(formats._table(FILTERS_81), {"palettegen", "tonemap", "zscale"})
        for text in (ENCODERS, MUXERS, MUXERS_6, FILTERS, FILTERS_81):
            names = formats._table(text)
            self.assertFalse(names & {"=", "------", "---", "--"}, text)
            self.assertFalse(any(name.endswith(":") for name in names), text)

    @unittest.skipUnless(HAVE_TOOLS, "ffmpeg and ffprobe are required")
    def test_installed_ffmpeg_tables(self):
        formats.clear_cache()
        self.addCleanup(formats.clear_cache)
        tools = formats.toolbox()
        self.assertIn("mp4", tools.muxers)
        self.assertIn("png", tools.encoders)
        self.assertTrue({"palettegen", "paletteuse", "scale"} <= tools.filters)

    def test_reduced_build_marks_formats(self):
        caps = {f["id"]: f for f in formats.capabilities(self.tools())["formats"]}
        self.assertFalse(caps["webp"]["available"])
        self.assertEqual(caps["webp"]["missing"], ["libwebp"])
        self.assertIn("libwebp", caps["webp"]["reason"])
        self.assertTrue(caps["webm"]["available"])
        self.assertFalse(caps["webm"]["audio"])
        self.assertEqual(caps["webm"]["audio_missing"], ["libopus"])
        self.assertTrue(caps["mp4"]["audio"])
        self.assertTrue(all(caps[i]["available"] for i in ("gif", "mp4", "png", "jpg", "tiff")))

    def test_gif_filters_only_for_animated_gif(self):
        tools = formats.Toolbox(self.tools().encoders, self.tools().muxers, frozenset())
        gif = formats.BY_ID["gif"]
        self.assertEqual(formats.missing_for(gif, tools), ["palettegen filter", "paletteuse filter"])
        self.assertEqual(formats.missing_for(gif, tools, still=True), [])
        self.assertEqual(formats.missing_for(gif, None), ["ffmpeg"])

    def test_aliases_and_menus(self):
        self.assertEqual(formats.normalize("JPEG"), "jpg")
        self.assertEqual(formats.normalize(".tif"), "tiff")
        self.assertIsNone(formats.normalize("avi"))
        caps = formats.capabilities(self.tools())
        self.assertEqual(caps["menus"]["image"], ["png", "jpg", "webp", "bmp", "tiff", "gif"])
        self.assertEqual(caps["menus"]["video"],
                         ["gif", "mp4", "webm", "mkv", "mov", "png", "jpg", "webp", "bmp", "tiff"])
        self.assertIn("heic", caps["input_extensions"])

    def test_single_sources(self):
        self.assertIs(launcher.MIME_TYPES, formats.INPUT_MIME_TYPES)
        qml = (ROOT / "OmaConvert.qml").read_text()
        self.assertNotIn('"--extensions", "mp4', qml, "picker extensions must come from the registry")
        model = (ROOT / "services/Model.js").read_text()
        # The offline fallback menus in Model.js mirror the registry.
        for kind, key in (("image", "FALLBACK_IMAGE"), ("video", "FALLBACK_VIDEO")):
            labels = re.search(key + r" = \[([^\]]*)\]", model).group(1)
            labels = [part.strip().strip('"') for part in labels.split(",")]
            self.assertEqual(labels, [f.label for f in formats.menu_order(kind)], kind)
        extensions = re.search(r"FALLBACK_EXTENSIONS = \"([^\"]*)\"", model).group(1).split()
        self.assertEqual(extensions, list(formats.INPUT_EXTENSIONS))


def run(env, *args):
    completed = subprocess.run([str(CLI), *map(str, args)], capture_output=True, text=True, env=env)
    events = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]
    return completed.returncode, events


@unittest.skipUnless(HAVE_TOOLS, "ffmpeg and ffprobe are required")
class ReducedBuildTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="omaconvert-formats-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        stubs = self.root / "bin"
        stubs.mkdir()
        for name, text in (("encoders", ENCODERS), ("muxers", MUXERS), ("filters", FILTERS)):
            (stubs / f"{name}.txt").write_text(text)
        stub = stubs / "ffmpeg"
        stub.write_text(
            "#!/bin/sh\n"
            f'here="{stubs}"\n'
            'case "$*" in\n'
            '  "-hide_banner -encoders") cat "$here/encoders.txt" ;;\n'
            '  "-hide_banner -muxers") cat "$here/muxers.txt" ;;\n'
            '  "-hide_banner -filters") cat "$here/filters.txt" ;;\n'
            f'  *) exec "{FFMPEG}" "$@" ;;\n'
            "esac\n")
        stub.chmod(stub.stat().st_mode | stat.S_IXUSR)
        self.env = dict(os.environ, PATH=f"{stubs}:{os.environ['PATH']}")
        self.image = self.root / "кадр [1] #2.png"
        subprocess.run([FFMPEG, "-v", "error", "-f", "lavfi", "-i", "testsrc2=s=64x48",
                        "-frames:v", "1", str(self.image)], check=True)

    def test_capabilities_event(self):
        code, events = run(self.env, "--capabilities")
        self.assertEqual(code, 0, events)
        self.assertEqual([e["event"] for e in events], ["dependencies", "capabilities"])
        caps = {f["id"]: f for f in events[-1]["formats"]}
        self.assertFalse(caps["webp"]["available"])
        self.assertTrue(caps["png"]["available"])

    def test_missing_encoder_fails_before_probe(self):
        code, events = run(self.env, self.image, "--format", "webp")
        self.assertEqual(code, 2)
        self.assertEqual(events[-1]["event"], "error")
        self.assertIn("libwebp", events[-1]["message"])
        self.assertNotIn("probe", [e["event"] for e in events], "no work before the capability check")
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ["bin", self.image.name])

    def test_audio_encoder_checked_only_for_sound(self):
        with_sound = self.root / "sound.mp4"
        silent = self.root / "silent.mp4"
        subprocess.run([FFMPEG, "-v", "error", "-f", "lavfi", "-i", "testsrc2=s=64x48:d=0.5",
                        "-f", "lavfi", "-i", "sine=d=0.5", "-shortest", "-pix_fmt", "yuv420p",
                        str(with_sound)], check=True)
        subprocess.run([FFMPEG, "-v", "error", "-f", "lavfi", "-i", "testsrc2=s=64x48:d=0.5",
                        "-pix_fmt", "yuv420p", str(silent)], check=True)
        code, events = run(self.env, with_sound, "--format", "webm", "--preset", "small")
        self.assertEqual(code, 2)
        self.assertIn("WebM with sound needs libopus", events[-1]["message"])
        self.assertNotIn("encoding", [e["event"] for e in events])
        code, events = run(self.env, silent, "--format", "webm", "--preset", "small")
        self.assertEqual(code, 0, events)
        self.assertTrue(Path(events[-1]["path"]).name.endswith(".webm"))


@unittest.skipUnless(HAVE_TOOLS, "ffmpeg and ffprobe are required")
class AliasTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="omaconvert-alias-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.image = self.root / "a.png"
        subprocess.run([FFMPEG, "-v", "error", "-f", "lavfi", "-i", "testsrc2=s=64x48",
                        "-frames:v", "1", str(self.image)], check=True)

    def test_alias_format_uses_canonical_default_name(self):
        code, events = run(os.environ, self.image, "--format", "JPEG", "--preset", "small")
        self.assertEqual(code, 0, events)
        self.assertEqual(Path(events[-1]["path"]).name, "a.jpg")
        code, events = run(os.environ, self.image, "--format", "tif", "--preset", "small")
        self.assertEqual(code, 0, events)
        self.assertEqual(Path(events[-1]["path"]).name, "a.tiff")

    def test_explicit_output_may_use_alias_extension(self):
        target = self.root / "photo.jpeg"
        code, events = run(os.environ, self.image, "--format", "jpg", "--output", target)
        self.assertEqual(code, 0, events)
        self.assertEqual(Path(events[-1]["path"]), target.resolve())
        code, events = run(os.environ, self.image, "--format", "jpg", "--output", self.root / "x.png")
        self.assertEqual(code, 2)
        self.assertIn("must end in .jpg", events[-1]["message"])


if __name__ == "__main__":
    unittest.main()
