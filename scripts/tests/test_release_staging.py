"""Exercise the actual workflow's two-architecture staging without GitHub access."""

import hashlib
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


class ReleaseStagingTests(unittest.TestCase):
    def test_kit_checksum_matches_the_selected_kit_and_both_cli_archives_survive(self):
        workflow = (
            Path(__file__).resolve().parents[2] / ".github/workflows/release.yml"
        ).read_text()
        start = workflow.index("          for architecture in ")
        end = workflow.index("          cp LICENSE", start)
        script = "set -euo pipefail\n" + textwrap.dedent(workflow[start:end])
        with tempfile.TemporaryDirectory(prefix="rill-staging-") as temporary:
            root = Path(temporary)
            (root / "publish").mkdir()
            for runner, architecture in (
                ("release-macos-15", "arm64"),
                ("release-macos-15-intel", "x86_64"),
            ):
                directory = root / "release-assets" / runner
                directory.mkdir(parents=True)
                for name in (
                    f"Rill-0.4.5-{architecture}-development.dmg",
                    f"Rill-0.4.5-{architecture}-development.sha256",
                    f"Rill-0.4.5-{architecture}-development.provenance.json",
                    f"RillCLI-0.4.5-{architecture}-development.zip",
                    f"RillCLI-0.4.5-{architecture}-development.zip.sha256",
                    f"RillCLI-0.4.5-{architecture}-development.provenance.json",
                ):
                    (directory / name).write_text(architecture)
                kit = architecture.encode()
                (directory / "Rill-Verification-Kit.zip").write_bytes(kit)
                (directory / "Rill-Verification-Kit.zip.sha256").write_text(
                    hashlib.sha256(kit).hexdigest() + "  Rill-Verification-Kit.zip\n"
                )
            subprocess.run(["bash", "-c", script], cwd=root, check=True, timeout=10)
            staged = root / "publish"
            kit = (staged / "Rill-Verification-Kit.zip").read_bytes()
            self.assertEqual(kit, b"arm64")
            checksum = (staged / "Rill-Verification-Kit.zip.sha256").read_text()
            self.assertEqual(checksum.split()[0], hashlib.sha256(kit).hexdigest())
            self.assertEqual(len(list(staged.glob("RillCLI-*.zip"))), 2)
            self.assertEqual(len(list(staged.glob("RillCLI-*.zip.sha256"))), 2)
            self.assertEqual(len(list(staged.glob("*.provenance.json"))), 4)


if __name__ == "__main__":
    unittest.main()
