import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "Sources/FrameCore"), str(ROOT / "Sources/FrameMCP")]
import Renderer
import server


class WorkflowTests(unittest.TestCase):
    def test_save_reopen_cli_mcp_parity(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            Image.new("RGBA", (120, 240), (200, 30, 60, 255)).save(base / "shot.png")
            doc = {"frameproj": 1, "screenshot": {"path": "shot.png"},
                   "frame": {"device": "Test device", "color": "Black", "output": "shot.png"},
                   "backdrop": {"color": "#203040", "grain": 6, "scale": 0.7},
                   "canvas": {"width": 320, "height": 180},
                   "custom": {"preserve": True}}
            project = base / "test.frameproj"
            Renderer.save_project(doc, project)
            loaded = Renderer.load_project(project)
            self.assertEqual(doc, loaded)
            expected = Renderer.render(loaded, base)
            self.assertEqual(expected.size, (320, 180))
            self.assertEqual(expected.tobytes(), Renderer.render(loaded, base).tobytes())
            cli = base / "cli.png"
            subprocess.run([sys.executable, str(ROOT / "Sources/FrameCore/Renderer.py"),
                            str(project), "-o", str(cli), "--json"], check=True, capture_output=True)
            response = server.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                      "params": {"name": "frame.render", "arguments": {
                                          "project": str(project), "output": str(base / "mcp")}}})
            self.assertFalse(response["result"]["isError"], response)
            result = json.loads(response["result"]["content"][0]["text"])
            self.assertEqual(expected.tobytes(), Image.open(cli).tobytes())
            self.assertEqual(expected.tobytes(), Image.open(result["output"]).tobytes())

    def test_orientation_is_normalized(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "rotated.jpg"
            image = Image.new("RGB", (80, 40), "red")
            exif = Image.Exif()
            exif[274] = 6
            image.save(path, exif=exif)
            self.assertEqual(Renderer.open_image(path).size, (40, 80))


if __name__ == "__main__":
    unittest.main()
