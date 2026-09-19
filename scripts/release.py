"""Version, draft, and package Catengar releases using only Python's standard library.

The prepare/upload commands run in GitHub Actions with its scoped GH_TOKEN.
Package can also run locally after a ReleaseSafe build.
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
VERSION_FILES = ("app.zon", "assets/catengar.rc", "assets/catengar-auth.rc")
EXECUTABLES = ("catengar.exe", "catengar-auth.exe", "catengar-diagnose.exe")
VERSION_PATTERN = re.compile(r'(?m)^(\s*\.version\s*=\s*")([^"\r\n]+)(",?\s*)$')


def parse_version(value):
    value = value.strip().removeprefix("v")
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:\.(0|[1-9][0-9]*))?", value):
        raise ValueError("Use a stable version such as v0.2 or 0.2.0 (major.minor or major.minor.patch).")
    parts = tuple(map(int, value.split(".")))
    if len(parts) == 2:
        parts += (0,)
    if any(part > 65535 for part in parts):
        raise ValueError("Windows executable version components cannot exceed 65535.")
    return parts


def version_text(parts):
    return ".".join(map(str, parts))


def current_version(root):
    matches = VERSION_PATTERN.findall((root / "app.zon").read_text(encoding="utf-8"))
    if len(matches) != 1:
        raise ValueError("Expected exactly one .version in app.zon.")
    return version_text(parse_version(matches[0][1]))


def next_version(current, requested="", bump="patch"):
    previous = parse_version(current)
    if requested.strip():
        candidate = parse_version(requested)
    else:
        index = ("major", "minor", "patch").index(bump)
        parts = list(previous)
        parts[index] += 1
        parts[index + 1:] = [0] * (2 - index)
        candidate = parse_version(version_text(parts))
    if candidate <= previous:
        raise ValueError(f"Release version must be greater than the current {current}.")
    return version_text(candidate)


def version_contents(root, version):
    """Validate every version field before any file is changed."""
    version = version_text(parse_version(version))
    current_version(root)
    result = {}
    manifest = (root / VERSION_FILES[0]).read_text(encoding="utf-8")
    result[VERSION_FILES[0]] = VERSION_PATTERN.sub(
        lambda match: match[1] + version + match[3], manifest
    )
    resource_version = version.replace(".", ",") + ",0"
    for name in VERSION_FILES[1:]:
        content = (root / name).read_text(encoding="utf-8")
        for field in ("FILEVERSION", "PRODUCTVERSION"):
            content, count = re.subn(
                rf"(?m)^{field}[ \t]+[0-9]+,[0-9]+,[0-9]+,[0-9]+[ \t]*$",
                f"{field} {resource_version}", content,
            )
            if count != 1:
                raise ValueError(f"Expected exactly one {field} in {name}.")
        result[name] = content
    return result


def set_version(root, version):
    for name, content in version_contents(root, version).items():
        (root / name).write_text(content, encoding="utf-8", newline="\n")


def verify_version(root, version):
    for name, expected in version_contents(root, version).items():
        if (root / name).read_text(encoding="utf-8") != expected:
            raise ValueError(f"{name} does not match release version {version}.")


def command(root, *args):
    result = subprocess.run(args, cwd=root, capture_output=True, text=True, encoding="utf-8")
    if result.returncode:
        raise RuntimeError(f"{args[0]} {args[1]} failed:\n{result.stderr.strip()}")
    return result.stdout.strip()


def git(root, *args):
    return command(root, "git", *args)


def gh(root, *args):
    return command(root, "gh", *args)


def release_marker(repository, run_id):
    return f"Catengar release | {repository} | run {run_id}"


def run_tag(root, repository, run_id):
    marker = release_marker(repository, run_id)
    refs = git(root, "for-each-ref", "--format=%(refname:strip=2)%09%(contents:subject)", "refs/tags")
    tags = [line.split("\t", 1)[0] for line in refs.splitlines()
            if line.partition("\t")[2] == marker]
    if len(tags) > 1:
        raise ValueError("Multiple tags belong to this workflow run; inspect them before retrying.")
    return tags[0] if tags else None


def find_release(root, repository, tag):
    # Pagination includes drafts and fails closed on API/auth errors.
    pages = json.loads(gh(root, "api", f"repos/{repository}/releases?per_page=100", "--paginate", "--slurp"))
    return next((release for page in pages for release in page if release["tag_name"] == tag), None)


def require_draft(release):
    if release is not None and not release["draft"]:
        raise ValueError("This release is already published; published releases are never overwritten.")


def prepare(root, repository, branch, run_id, requested="", bump="patch"):
    if git(root, "status", "--porcelain"):
        raise ValueError("Release preparation requires a clean checkout.")
    git(root, "fetch", "origin", f"refs/heads/{branch}:refs/remotes/origin/{branch}", "--tags")
    tag = run_tag(root, repository, run_id)
    if tag:
        # GITHUB_RUN_ID is unchanged on rerun: reuse exactly the tagged commit,
        # even if the default branch has since advanced to another version.
        version = version_text(parse_version(tag))
        if requested.strip() and version_text(parse_version(requested)) != version:
            raise ValueError("The requested version differs from this run's existing tag.")
        release = find_release(root, repository, tag)
        require_draft(release)
        git(root, "checkout", "--detach", f"refs/tags/{tag}")
        verify_version(root, version)
    else:
        git(root, "checkout", "--detach", f"refs/remotes/origin/{branch}")
        version = next_version(current_version(root), requested, bump)
        tag = f"v{version}"
        if tag in git(root, "tag", "--list").splitlines():
            raise ValueError(f"Tag {tag} already exists. Rerun its original workflow or use a newer version.")
        release = find_release(root, repository, tag)
        if release is not None:
            raise ValueError(f"Release {tag} already exists; it will not be reused by a new run.")
        set_version(root, version)
        git(root, "config", "user.name", "github-actions[bot]")
        git(root, "config", "user.email", "41898282+github-actions[bot]@users.noreply.github.com")
        git(root, "add", "--", *VERSION_FILES)
        git(root, "commit", "-m", f"chore: release {tag}")
        git(root, "tag", "-a", tag, "-m", release_marker(repository, run_id))
        # Neither ref is published if branch protection or a concurrent push
        # rejects the update. No force push or branch protection bypass.
        git(root, "push", "--atomic", "origin", f"HEAD:refs/heads/{branch}", f"refs/tags/{tag}")

    commit = git(root, "rev-parse", "HEAD")
    if release is None:
        with tempfile.TemporaryDirectory(prefix="catengar-release-notes-") as directory:
            notes = Path(directory) / "notes.md"
            notes.write_text(
                f"Windows x64 portable application.\n\n"
                f"Download `catengar-{tag}-windows-x64.zip`, extract all files into the same "
                "directory, and launch `catengar.exe`. Keep `catengar-auth.exe` beside it.\n",
                encoding="utf-8",
            )
            gh(root, "release", "create", tag, "--repo", repository, "--draft", "--verify-tag",
               "--target", commit, "--title", f"Catengar {tag}", "--notes-file", str(notes),
               "--generate-notes")
        release = find_release(root, repository, tag)
    if release is None:
        raise RuntimeError("The draft release could not be read after creation; rerun this workflow.")
    require_draft(release)
    return {"version": version, "tag": tag, "commit": commit, "release_url": release["html_url"]}


def package(root, version, build_dir, output_dir):
    version = version_text(parse_version(version))
    verify_version(root, version)
    files = [build_dir / name for name in EXECUTABLES] + [root / "README.md"]
    for path in files:
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"Required release file is missing or empty: {path}")
    output_dir.mkdir(parents=True, exist_ok=True)
    archive = output_dir / f"catengar-v{version}-windows-x64.zip"
    # A failed write must not leave a partial archive under the final asset name.
    with tempfile.TemporaryDirectory(prefix="package-", dir=output_dir) as directory:
        temporary = Path(directory) / archive.name
        with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as output:
            for path in files:
                output.write(path, path.name)
        temporary.replace(archive)
    return archive


def upload(root, repository, run_id, tag, archive):
    if run_tag(root, repository, run_id) != tag:
        raise ValueError("The asset must belong to this workflow run's release tag.")
    if git(root, "rev-parse", "HEAD") != git(root, "rev-parse", f"refs/tags/{tag}^{{commit}}"):
        raise ValueError("The build checkout does not match the release tag.")
    version = version_text(parse_version(tag))
    verify_version(root, version)
    if archive.name != f"catengar-v{version}-windows-x64.zip" or not archive.is_file():
        raise ValueError("The release archive is missing or has the wrong versioned filename.")
    release = find_release(root, repository, tag)
    if release is None:
        raise ValueError("The draft release is missing; rerun this workflow to restore it.")
    require_draft(release)
    gh(root, "release", "upload", tag, str(archive), "--repo", repository, "--clobber")


def actions_output(values):
    for key, value in values.items():
        print(f"{key}={value}")
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a", encoding="utf-8", newline="\n") as stream:
            for key, value in values.items():
                stream.write(f"{key}={value}\n")


def actions_context():
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch":
        raise ValueError("Release preparation and upload must run through the manual GitHub Actions workflow.")
    repository = os.environ["GITHUB_REPOSITORY"]
    run_id = os.environ["GITHUB_RUN_ID"]
    branch = os.environ["RELEASE_BRANCH"]
    if os.environ.get("GITHUB_REF") != f"refs/heads/{branch}":
        raise ValueError("Run this release workflow from the repository's default branch.")
    return repository, branch, run_id


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare", help="Commit the version, tag, and create/reuse a draft")
    prepare_parser.add_argument("--version", default=os.environ.get("RELEASE_VERSION", ""),
                                help="Optional version, e.g. v0.2 or 0.2.0; missing patch defaults to 0")
    prepare_parser.add_argument("--bump", choices=("patch", "minor", "major"), default="patch")
    package_parser = commands.add_parser("package", help="Zip the three executables and README")
    package_parser.add_argument("--version", required=True)
    package_parser.add_argument("--build-dir", type=Path, default=ROOT / "zig-out/bin")
    package_parser.add_argument("--output-dir", type=Path, default=ROOT / "artifacts/release")
    upload_parser = commands.add_parser("upload", help="Upload the ZIP to this run's draft release")
    upload_parser.add_argument("--tag", required=True)
    upload_parser.add_argument("--archive", required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == "package":
            archive = package(ROOT, args.version, args.build_dir, args.output_dir)
            actions_output({"archive": archive.resolve().as_posix()})
        else:
            repository, branch, run_id = actions_context()
            if args.command == "prepare":
                actions_output(prepare(ROOT, repository, branch, run_id, args.version, args.bump))
            else:
                upload(ROOT, repository, run_id, args.tag, args.archive)
    except (OSError, ValueError, RuntimeError, KeyError) as error:
        print(f"Release failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
