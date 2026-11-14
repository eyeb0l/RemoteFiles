import hashlib
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = ROOT / "Sources" / "RemoteFilesCore" / "Resources" / "MarkdownRenderer"
ROW = re.compile(r"^\| (\w+) \| [\w.]+ \| `([0-9a-f]{64})` \|$", re.MULTILINE)


class BundledRendererTests(unittest.TestCase):
    """The bundled libraries are minified, and one is 5.5 MB: a change to them cannot be reviewed
    by eye. Their recorded hashes are of the files as published, so a file that differs is not
    the release UPSTREAM.md names."""

    def recorded(self):
        return dict(ROW.findall((BUNDLE / "UPSTREAM.md").read_text()))

    def test_every_bundled_library_matches_its_recorded_hash(self):
        recorded = self.recorded()
        self.assertEqual(set(recorded), {"mermaid", "katex", "marked", "dompurify"})
        for library, expected in recorded.items():
            with self.subTest(library=library):
                actual = hashlib.sha256((BUNDLE / (library + ".js")).read_bytes()).hexdigest()
                self.assertEqual(actual, expected, library + ".js is not the distribution UPSTREAM.md records")

    def test_no_other_script_is_bundled_without_a_recorded_hash(self):
        scripts = {path.stem for path in BUNDLE.glob("*.js")}
        # markdown-renderer.js is this project's own integration, reviewed as source.
        self.assertEqual(scripts - {"markdown-renderer"}, set(self.recorded()))


if __name__ == "__main__":
    unittest.main()
