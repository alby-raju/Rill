#!/usr/bin/env python3
"""Exercise synthetic request/response tab changes in an isolated debug app."""

import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
subprocess.run(["swift", "build", "--product", "Rill"], cwd=ROOT, check=True)
products = Path(
    subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, text=True).strip()
)
with tempfile.TemporaryDirectory(prefix="rill-tab-resize-") as directory:
    folder = Path(directory)
    app = folder / "Rill.app"
    subprocess.run(["ditto", str(ROOT / "dist/Rill.app"), str(app)], check=True)
    subprocess.run(["ditto", str(products / "Rill"), str(app / "Contents/MacOS/Rill")], check=True)
    subprocess.run(
        ["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True
    )
    for layout in ["vertical", "horizontal"]:
        output = folder / (layout + ".log")
        error = folder / (layout + ".err")
        subprocess.run(
            [
                "/usr/bin/open",
                "-n",
                "-W",
                "--stdout",
                str(output),
                "--stderr",
                str(error),
                str(app),
                "--args",
                "--ui-state",
                "response-resize",
                "--ui-layout",
                layout,
                "--ui-snapshot",
                str(folder / (layout + ".png")),
            ],
            check=True,
            timeout=45,
        )
        expected = "RILL_TAB_RESIZE_OK orientation=" + layout + " cases=210"
        if (
            not output.exists()
            or expected not in output.read_text()
            or not (folder / (layout + ".png")).exists()
        ):
            if output.exists():
                print(output.read_text()[:8192])
            if error.exists():
                print(error.read_text()[:8192])
            raise SystemExit("Synthetic tab resize check failed: " + layout)
        for line in output.read_text().splitlines():
            if line.startswith("RILL_TAB_RESIZE_VIEWPORT"):
                print(line)
        print(expected)
