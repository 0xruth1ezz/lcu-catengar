"""Offline release regression tests. Git remotes are local; GitHub calls are faked."""

import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import release


class VersionTests(unittest.TestCase):
    def test_automatic_bumps(self):
        self.assertEqual(release.next_version("0.1.0"), "0.1.1")
        self.assertEqual(release.next_version("1.2.9", bump="minor"), "1.3.0")
        self.assertEqual(release.next_version("1.2.9", bump="major"), "2.0.0")

    def test_optional_explicit_version_takes_precedence(self):
        self.assertEqual(release.next_version("0.1.0", " v0.3.4 ", "major"), "0.3.4")
        self.assertEqual(release.next_version("0.1.0", " "), "0.1.1")

    def test_short_versions_normalize_to_three_components(self):
        for value in ("v0.2", "0.2", " v0.2 ", "0.2.0", "v0.2.0"):
            with self.subTest(value=value):
                self.assertEqual(release.next_version("0.1.0", value, "major"), "0.2.0")

    def test_invalid_or_non_increasing_versions(self):
        for value in ("0.1.0", "v0.1", "0.0.9", "0", "v", "0.2.", "0.2.0.0", "0.02",
                      "01.2.3", "1.2.3-beta.1", "1.2.3+abc", "1.2.3\ninjected=true", "--help",
                      "65536.0.0", "65536.0"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.next_version("0.1.0", value)
        with self.assertRaises(ValueError):
            release.next_version("1.2.65535")


class ReleaseFilesFixture(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="catengar-release-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name) / "checkout"
        (self.root / "assets").mkdir(parents=True)
        for name in release.VERSION_FILES:
            shutil.copyfile(release.ROOT / name, self.root / name)
        # Tests remain independent of the repository's next release version.
        release.set_version(self.root, "0.1.0")
        (self.root / "README.md").write_text("Catengar portable app\n", encoding="utf-8")

    def binaries(self):
        directory = self.root / "zig-out/bin"
        directory.mkdir(parents=True)
        for name in release.EXECUTABLES:
            (directory / name).write_bytes(b"fixture: " + name.encode())
        (directory / "catengar-auth-fixture.exe").write_bytes(b"must not ship")
        return directory


class FilesTests(ReleaseFilesFixture):
    def test_version_updates_manifest_and_both_executable_resources(self):
        release.set_version(self.root, "1.2.3")
        release.verify_version(self.root, "1.2.3")
        self.assertEqual(release.current_version(self.root), "1.2.3")
        for name in release.VERSION_FILES[1:]:
            content = (self.root / name).read_text()
            self.assertIn("FILEVERSION 1,2,3,0", content)
            self.assertIn("PRODUCTVERSION 1,2,3,0", content)

    def test_bad_resource_does_not_partially_update_version(self):
        path = self.root / release.VERSION_FILES[-1]
        path.write_text(path.read_text().replace("FILEVERSION", "BROKEN"))
        before = {name: (self.root / name).read_bytes() for name in release.VERSION_FILES}
        with self.assertRaises(ValueError):
            release.set_version(self.root, "0.2.0")
        self.assertEqual(before, {name: (self.root / name).read_bytes() for name in release.VERSION_FILES})

    def test_zip_name_and_complete_portable_contents(self):
        binaries = self.binaries()
        archive = release.package(self.root, "v0.1.0", binaries, self.root / "artifacts/release")
        self.assertEqual(archive.name, "catengar-v0.1.0-windows-x64.zip")
        with zipfile.ZipFile(archive) as output:
            self.assertEqual(set(output.namelist()), {*release.EXECUTABLES, "README.md"})
            self.assertIsNone(output.testzip())
            for name in release.EXECUTABLES:
                self.assertEqual(output.read(name), (binaries / name).read_bytes())

    def test_missing_helper_or_wrong_version_cannot_be_packaged(self):
        binaries = self.binaries()
        output = self.root / "artifacts/release"
        with self.assertRaises(ValueError):
            release.package(self.root, "0.2.0", binaries, output)
        (binaries / "catengar-auth.exe").unlink()
        with self.assertRaises(ValueError):
            release.package(self.root, "0.1.0", binaries, output)
        self.assertFalse(output.exists())


class GitHubFixture:
    def __init__(self):
        self.releases = []
        self.creates = 0
        self.uploads = []
        self.fail_create = False
        self.hide_lookup = False
        self.lookups = 0

    def __call__(self, root, *args):
        if args[:2] == ("api", "graphql"):
            self.lookups += 1
            tag = next(value.removeprefix("tag=") for value in args if value.startswith("tag="))
            found = next((item for item in self.releases if item["tag_name"] == tag), None)
            item = None
            if found and not self.hide_lookup:
                item = {"databaseId": found["id"], "tagName": found["tag_name"],
                        "isDraft": found["draft"], "url": found["html_url"]}
            return json.dumps({"data": {"repository": {"release": item}}})
        if args[:2] == ("api", "repos/fixture/catengar/releases") and "POST" in args:
            if self.fail_create:
                raise RuntimeError("Simulated GitHub outage after tag push")
            payload = json.loads(Path(args[args.index("--input") + 1]).read_text(encoding="utf-8"))
            assert payload["draft"] is True and payload["prerelease"] is False
            assert payload["generate_release_notes"] is True
            assert "catengar-auth.exe" in payload["body"]
            self.creates += 1
            tag = payload["tag_name"]
            self.releases.append({"id": self.creates, "tag_name": tag, "draft": True,
                                  "html_url": f"https://example.test/untagged-{self.creates}"})
            return json.dumps(self.releases[-1])
        if args[:2] == ("release", "upload"):
            self.uploads.append(args)
            return ""
        raise AssertionError(f"Unexpected GitHub command: {args}")


class PrepareTests(ReleaseFilesFixture):
    def setUp(self):
        super().setUp()
        self.remote = Path(self.directory.name) / "origin.git"
        release.git(self.root, "init", "--bare", str(self.remote))
        release.git(self.root, "init", "--initial-branch=main")
        release.git(self.root, "config", "user.name", "Release Test")
        release.git(self.root, "config", "user.email", "release@example.test")
        release.git(self.root, "config", "core.autocrlf", "false")
        release.git(self.root, "config", "commit.gpgsign", "false")
        release.git(self.root, "config", "tag.gpgsign", "false")
        release.git(self.root, "add", ".")
        release.git(self.root, "commit", "-m", "Initial fixture")
        release.git(self.root, "remote", "add", "origin", str(self.remote))
        release.git(self.root, "push", "origin", "main")
        self.api = GitHubFixture()
        patcher = patch.object(release, "gh", self.api)
        patcher.start()
        self.addCleanup(patcher.stop)

    def prepare(self, run_id="123", requested="", root=None):
        return release.prepare(root or self.root, "fixture/catengar", "main", run_id, requested)

    def clone(self, name):
        root = Path(self.directory.name) / name
        release.git(self.root, "clone", "--branch", "main", str(self.remote), str(root))
        release.git(root, "config", "commit.gpgsign", "false")
        release.git(root, "config", "tag.gpgsign", "false")
        return root

    def test_bump_commit_tag_and_draft_then_resume_same_run(self):
        first = self.prepare()
        second = self.prepare(root=self.clone("retry"))
        self.assertEqual(first, second)
        self.assertEqual(first["tag"], "v0.1.1")
        self.assertEqual(self.api.creates, 1)
        self.assertEqual(release.git(self.root, "status", "--porcelain"), "")
        self.assertEqual(release.git(self.remote, "rev-parse", "main"), first["commit"])
        self.assertEqual(release.git(self.remote, "rev-parse", "v0.1.1^{commit}"), first["commit"])

    def test_explicit_version_and_retry_after_another_release(self):
        first = self.prepare(requested="v0.2")
        second = self.prepare(run_id="124", requested="0.3.0")
        retried = self.prepare(requested="0.2.0", root=self.clone("retry"))
        self.assertEqual(first, retried)
        self.assertEqual(release.git(self.remote, "rev-parse", "main"), second["commit"])
        self.assertEqual(self.api.creates, 2)

    def test_short_version_produces_canonical_tag_resources_and_asset(self):
        result = self.prepare(requested="v0.2")
        self.assertEqual(result["version"], "0.2.0")
        self.assertEqual(result["tag"], "v0.2.0")
        release.verify_version(self.root, "0.2.0")
        archive = release.package(self.root, "0.2", self.binaries(), Path(self.directory.name) / "output")
        self.assertEqual(archive.name, "catengar-v0.2.0-windows-x64.zip")
        release.upload(self.root, "fixture/catengar", "123", result["tag"], archive)
        self.assertEqual(self.api.uploads[0][2], "v0.2.0")
        self.assertEqual(self.api.uploads[0][3], str(archive))

    def test_retry_after_tag_push_but_before_draft_creation(self):
        self.api.fail_create = True
        with self.assertRaises(RuntimeError):
            self.prepare()
        self.api.fail_create = False
        result = self.prepare(root=self.clone("retry"))
        self.assertEqual(result["version"], "0.1.1")
        self.assertEqual(self.api.creates, 1)

    def test_create_response_succeeds_even_when_release_lookup_is_stale(self):
        self.api.hide_lookup = True
        result = self.prepare()
        self.assertEqual(result["release_url"], "https://example.test/untagged-1")
        self.assertEqual(result["tag"], "v0.1.1")
        self.assertEqual(self.api.lookups, 1)
        self.assertEqual(self.api.creates, 1)

    def test_retry_preserves_fixed_helper_when_building_original_tag(self):
        helper = self.root / "scripts/release.py"
        helper.parent.mkdir()
        helper.write_text("# original release helper\n")
        release.git(self.root, "add", "scripts/release.py")
        release.git(self.root, "commit", "-m", "Original release tooling")
        release.git(self.root, "push", "origin", "HEAD:main")
        original = self.prepare()

        helper.write_text("# corrected release helper\n")
        release.git(self.root, "add", "scripts/release.py")
        release.git(self.root, "commit", "-m", "Fix release tooling after failed run")
        release.git(self.root, "push", "origin", "HEAD:main")
        retry = self.clone("retry")
        result = self.prepare(root=retry)

        self.assertEqual(result, original)
        self.assertEqual((retry / "scripts/release.py").read_text(), "# corrected release helper\n")
        self.assertEqual(release.git(retry, "show", "HEAD:scripts/release.py"), "# original release helper")
        self.assertEqual(release.git(retry, "diff", "--name-only"), "scripts/release.py")
        self.assertEqual(self.api.creates, 1)

    def test_missing_remote_tag_cannot_be_silently_recreated_by_release_api(self):
        result = self.prepare()
        release.git(self.remote, "update-ref", "-d", "refs/tags/v0.1.1")
        with self.assertRaises(RuntimeError):
            release.create_draft(self.root, "fixture/catengar", result["tag"], result["commit"])
        self.assertEqual(self.api.creates, 1)

    def test_graphql_errors_do_not_look_like_a_missing_release(self):
        response = json.dumps({"errors": [{"message": "Forbidden"}], "data": {"repository": None}})
        with patch.object(release, "gh", return_value=response):
            with self.assertRaisesRegex(RuntimeError, "release state"):
                self.prepare()
        self.assertEqual(release.current_version(self.root), "0.1.0")
        self.assertEqual(release.git(self.remote, "tag", "--list"), "")

    def test_published_release_cannot_be_rebuilt_or_overwritten(self):
        result = self.prepare()
        self.api.releases[0]["draft"] = False
        with self.assertRaisesRegex(ValueError, "already published"):
            self.prepare()
        archive = Path(self.directory.name) / f"catengar-{result['tag']}-windows-x64.zip"
        archive.write_bytes(b"fixture")
        with self.assertRaisesRegex(ValueError, "already published"):
            release.upload(self.root, "fixture/catengar", "123", result["tag"], archive)
        self.assertFalse(self.api.uploads)

    def test_upload_accepts_only_own_draft_and_matching_build(self):
        result = self.prepare()
        archive = Path(self.directory.name) / f"catengar-{result['tag']}-windows-x64.zip"
        archive.write_bytes(b"fixture")
        with self.assertRaises(ValueError):
            release.upload(self.root, "fixture/catengar", "999", result["tag"], archive)
        release.upload(self.root, "fixture/catengar", "123", result["tag"], archive)
        self.assertEqual(len(self.api.uploads), 1)
        self.assertIn("--clobber", self.api.uploads[0])
        release.git(self.root, "checkout", "--detach", "HEAD^")
        with self.assertRaisesRegex(ValueError, "does not match"):
            release.upload(self.root, "fixture/catengar", "123", result["tag"], archive)

    def test_existing_tag_is_not_reused_by_new_run(self):
        release.git(self.root, "tag", "v0.1.1")
        release.git(self.root, "push", "origin", "v0.1.1")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.prepare()
        self.assertEqual(release.current_version(self.root), "0.1.0")
        self.assertFalse(self.api.creates)

    def test_api_failure_does_not_commit_version(self):
        before = release.git(self.remote, "rev-parse", "main")
        with patch.object(release, "gh", side_effect=RuntimeError("API unavailable")):
            with self.assertRaises(RuntimeError):
                self.prepare()
        self.assertEqual(release.current_version(self.root), "0.1.0")
        self.assertEqual(release.git(self.remote, "rev-parse", "main"), before)

    def test_concurrent_branch_push_rejects_both_release_refs(self):
        other = self.clone("other")
        release.git(other, "config", "user.name", "Other Committer")
        release.git(other, "config", "user.email", "other@example.test")
        (other / "README.md").write_text("A newer commit\n")
        release.git(other, "add", "README.md")
        release.git(other, "commit", "-m", "Concurrent change")

        def concurrent_api(root, *args):
            release.git(other, "push", "origin", "main")
            return self.api(root, *args)

        with patch.object(release, "gh", concurrent_api):
            with self.assertRaises(RuntimeError):
                self.prepare()
        self.assertEqual(release.git(self.remote, "tag", "--list"), "")
        self.assertEqual(release.git(self.remote, "show", "main:app.zon"),
                         (other / "app.zon").read_text().strip())
        self.assertFalse(self.api.creates)


if __name__ == "__main__":
    unittest.main()
