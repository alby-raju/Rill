"""Regression coverage for fail-closed repository/release checks."""

import importlib.util
import io
import json
import os
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parent.parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RepositoryChecks(unittest.TestCase):
    def test_vulnerability_scan_rejects_matches_and_incomplete_service_results(self):
        audit = load("security-audit")
        count = len(json.loads((audit.ROOT / "Package.resolved").read_text())["pins"]) + 1
        for results, expected in [([{}] * count, 0), ([{"vulns": [{"id": "TEST-1"}]}] * count, 1)]:
            response = io.BytesIO(json.dumps({"results": results}).encode())
            with (
                patch.object(audit, "urlopen", return_value=response),
                patch("sys.stdout", new=io.StringIO()),
            ):
                self.assertEqual(audit.main(), expected)
        for results in [[], [{"error": "service failure"}] * count]:
            response = io.BytesIO(json.dumps({"results": results}).encode())
            with (
                patch.object(audit, "urlopen", return_value=response),
                self.assertRaises(ValueError),
            ):
                audit.main()

    def test_release_requires_new_versioned_tag_main_and_successful_checks(self):
        release = load("validate-release")
        names = [
            "Build and test on macOS",
            "Dependency vulnerability scan",
            "CodeQL / swift",
            "CodeQL / python",
        ]
        checks = {
            "check_runs": [
                {"name": name, "conclusion": "success", "app": {"slug": "github-actions"}}
                for name in names
            ]
        }
        env = {
            "GITHUB_REF": "refs/heads/main",
            "GITHUB_REPOSITORY": "owner/repo",
            "GITHUB_SHA": "abc",
        }
        with patch.dict(os.environ, env), patch("sys.argv", ["validate-release", "v0.4.0-dev.1"]):
            with (
                patch.object(release, "api", side_effect=[[], [], checks]),
                patch("sys.stdout", new=io.StringIO()),
            ):
                release.main()
            for replies in [
                [[{"ref": "refs/tags/v0.4.0-dev.1"}]],
                [[], [{"tag_name": "v0.4.0-dev.1"}]],
                [[], [], {"check_runs": []}],
            ]:
                with (
                    patch.object(release, "api", side_effect=replies),
                    self.assertRaises(ValueError),
                ):
                    release.main()
            with (
                patch.dict(os.environ, {"GITHUB_REF": "refs/heads/feature"}),
                self.assertRaises(ValueError),
            ):
                release.main()
            with (
                patch("sys.argv", ["validate-release", "v9.0.0-dev.1"]),
                self.assertRaises(ValueError),
            ):
                release.main()


if __name__ == "__main__":
    unittest.main()
