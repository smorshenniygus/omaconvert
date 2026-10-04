import json
from pathlib import Path
import re
import subprocess
import unittest

import lib

ROOT = Path(__file__).resolve().parents[1]


class VersionTests(unittest.TestCase):
    """The interface compares its own version with the backend's at runtime to
    detect a shell that kept stale cached QML after an update, so all three
    declarations must move together."""

    def test_manifest_backend_and_interface_versions_match(self):
        manifest = json.loads((ROOT / "manifest.json").read_text())["version"]
        model = re.search(r'^var VERSION = "([^"]+)"', (ROOT / "services/Model.js").read_text(), re.M)
        self.assertIsNotNone(model, "services/Model.js must declare VERSION")
        self.assertEqual(lib.__version__, manifest)
        self.assertEqual(model.group(1), manifest)

    def test_interface_fallback_id_matches_manifest(self):
        manifest = json.loads((ROOT / "manifest.json").read_text())["id"]
        model = re.search(r'^var PLUGIN_ID = "([^"]+)"', (ROOT / "services/Model.js").read_text(), re.M)
        self.assertIsNotNone(model, "services/Model.js must declare PLUGIN_ID")
        self.assertEqual(model.group(1), manifest)

    def test_cli_reports_version_as_json(self):
        completed = subprocess.run([str(ROOT / "bin/omaconvert"), "--version"],
                                   capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(completed.stdout), {"event": "version", "version": lib.__version__})


if __name__ == "__main__":
    unittest.main()
