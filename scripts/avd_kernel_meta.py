#!/usr/bin/env python3
"""Parse AVD kernel versions and produce reproducible build metadata."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any


BRANCH_RULES = (
    (re.compile(r"^6\.6\.\d+-android15-\d+$"), "common-android15-6.6"),
    (re.compile(r"^6\.1\.\d+-android14-\d+$"), "common-android14-6.1"),
    (re.compile(r"^5\.15\.\d+-android14-\d+$"), "common-android14-5.15"),
    (re.compile(r"^5\.15\.\d+-android13-\d+$"), "common-android13-5.15"),
    (re.compile(r"^5\.10\.\d+-android12-\d+$"), "common-android12-5.10"),
    (re.compile(r"^5\.4\.\d+-android11-\d+$"), "common-android11-5.4"),
)

FALLBACK_REPO_PATHS = {
    "kernel/common": ("common",),
    "kernel/common-modules/virtual-device": ("common-modules/virtual-device",),
    "kernel/build": ("build/kernel", "build"),
    "kernel/configs": ("kernel/configs",),
    "kernel/prebuilts/build-tools": ("prebuilts/kernel-build-tools",),
    "platform/build/bazel_common_rules": ("build/bazel_common_rules",),
    "platform/external/bazel-skylib": ("external/bazel-skylib",),
    "platform/external/python/absl-py": ("external/python/absl-py",),
    "platform/external/stardoc": ("external/stardoc",),
    "platform/prebuilts/bazel/linux-x86_64": ("prebuilts/bazel/linux-x86_64",),
    "platform/prebuilts/build-tools": ("prebuilts/build-tools",),
    "platform/prebuilts/clang-tools": ("prebuilts/clang-tools",),
    "platform/prebuilts/clang/host/linux-x86": ("prebuilts/clang/host/linux-x86",),
    "platform/prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8": (
        "prebuilts/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8",
    ),
    "platform/prebuilts/jdk/jdk11": ("prebuilts/jdk/jdk11",),
    "platform/system/tools/mkbootimg": ("tools/mkbootimg",),
    "toolchain/prebuilts/ndk/r23": ("prebuilts/ndk-r23",),
}


def read_proc_version(args: argparse.Namespace) -> str:
    if getattr(args, "proc_version", None):
        return args.proc_version.strip()
    if getattr(args, "proc_version_file", None):
        path = args.proc_version_file
        if path == "-":
            return sys.stdin.read().strip()
        return Path(path).read_text(encoding="utf-8").strip()
    return ""


def branch_for_kernel(kernel_ver: str) -> str:
    for pattern, branch in BRANCH_RULES:
        if pattern.match(kernel_ver):
            return branch
    raise SystemExit(f"Unsupported kernel version pattern: {kernel_ver}")


def parse_proc_version(text: str) -> dict[str, str]:
    kernel_match = re.search(r"Linux version ([0-9]+\.[0-9]+\.[0-9]+-android\d+-\d+)", text)
    commit_match = re.search(r"-g([0-9a-f]{12,40})(?:[-\s])", text)
    build_match = re.search(r"-ab(\d+)", text)
    if not kernel_match:
        raise SystemExit("Cannot parse kernel version from /proc/version")
    if not commit_match:
        raise SystemExit("Cannot parse common commit after '-g' from /proc/version")
    if not build_match:
        raise SystemExit("Cannot parse Android CI build id after '-ab' from /proc/version")

    kernel_ver = kernel_match.group(1)
    commit = commit_match.group(1)
    build_id = build_match.group(1)
    series = ".".join(kernel_ver.split("-", 1)[0].split(".")[:2])
    android = re.search(r"-(android\d+)-", kernel_ver).group(1)
    return {
        "proc_version": text,
        "kernel_version": kernel_ver,
        "kernel_series": series,
        "android_release": android,
        "repo_branch": branch_for_kernel(kernel_ver),
        "common_commit_from_proc": commit,
        "build_id": build_id,
        "build_tag": f"ab{build_id}",
    }


def load_gitiles_json(url: str) -> dict[str, Any]:
    with urllib.request.urlopen(url, timeout=30) as response:
        body = response.read().decode("utf-8")
    if body.startswith(")]}'"):
        body = body.split("\n", 1)[1]
    return json.loads(body)


def fetch_text_url(url: str) -> str:
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read().decode("utf-8")


def artifact_url_from_viewer_html(body: str) -> str:
    match = re.search(r"var JSVariables = (\{.*?\});", body, re.DOTALL)
    if not match:
        return ""
    try:
        data = json.loads(match.group(1))
    except json.JSONDecodeError:
        return ""
    return str(data.get("artifactUrl", ""))


def fetch_json_artifact(url: str) -> tuple[dict[str, Any], str]:
    body = fetch_text_url(url)
    try:
        return json.loads(body), ""
    except json.JSONDecodeError as direct_error:
        artifact_url = artifact_url_from_viewer_html(body)
        if not artifact_url:
            raise direct_error
        artifact_body = fetch_text_url(artifact_url)
        return json.loads(artifact_body), artifact_url


def resolve_common_commit(short_or_full: str) -> str:
    if len(short_or_full) >= 40:
        return short_or_full
    url = f"https://android.googlesource.com/kernel/common/+/{short_or_full}?format=JSON"
    data = load_gitiles_json(url)
    commit = data.get("commit")
    if not commit:
        raise RuntimeError(f"Gitiles did not return a full commit for {short_or_full}")
    return commit


def build_metadata(args: argparse.Namespace) -> dict[str, Any]:
    text = read_proc_version(args)
    if text:
        meta: dict[str, Any] = parse_proc_version(text)
    else:
        if not args.repo_branch:
            raise SystemExit("--repo-branch is required when --proc-version is not provided")
        meta = {
            "proc_version": "",
            "kernel_version": args.kernel_version or "",
            "kernel_series": "",
            "android_release": "",
            "repo_branch": args.repo_branch,
            "common_commit_from_proc": args.common_commit or "",
            "build_id": args.build_id or "",
            "build_tag": f"ab{args.build_id}" if args.build_id else "",
        }

    ci_target = args.ci_target
    build_id = args.build_id or meta.get("build_id") or ""
    build_info_url = ""
    artifact_url = ""
    build_info: dict[str, Any] | None = None
    ci_error = ""
    if build_id:
        build_info_url = (
            f"https://ci.android.com/builds/submitted/{build_id}/"
            f"{ci_target}/latest/view/BUILD_INFO"
        )
        try:
            build_info, artifact_url = fetch_json_artifact(build_info_url)
        except (urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError) as exc:
            ci_error = str(exc)

    repo_commits: dict[str, str] = {}
    if build_info:
        repo_commits.update(build_info.get("repo-dict", {}))

    if "kernel/common" not in repo_commits and meta.get("common_commit_from_proc"):
        try:
            repo_commits["kernel/common"] = resolve_common_commit(meta["common_commit_from_proc"])
        except Exception as exc:  # noqa: BLE001 - preserve useful warning in metadata.
            ci_error = f"{ci_error}; common commit resolve failed: {exc}".strip("; ")
            repo_commits["kernel/common"] = meta["common_commit_from_proc"]

    meta["ci"] = {
        "target": ci_target,
        "build_info_url": build_info_url,
        "artifact_url": artifact_url,
        "build_info_found": build_info is not None,
        "error": ci_error,
    }
    meta["repo_commits"] = repo_commits
    if build_info:
        meta["ci"]["branch"] = build_info.get("branch", "")
        meta["ci"]["bid"] = build_info.get("bid", "")
    return meta


def emit_env(meta: dict[str, Any]) -> None:
    values = {
        "AVD_PROC_VERSION": meta.get("proc_version", ""),
        "AVD_KERNEL_VERSION": meta.get("kernel_version", ""),
        "AVD_REPO_BRANCH": meta.get("repo_branch", ""),
        "AVD_BUILD_ID": meta.get("build_id", ""),
        "AVD_BUILD_TAG": meta.get("build_tag", ""),
        "AVD_COMMON_COMMIT": meta.get("repo_commits", {}).get(
            "kernel/common", meta.get("common_commit_from_proc", "")
        ),
        "AVD_CI_TARGET": meta.get("ci", {}).get("target", ""),
        "AVD_CI_BUILD_INFO_FOUND": "1" if meta.get("ci", {}).get("build_info_found") else "0",
    }
    for key, value in values.items():
        print(f"export {key}={shlex.quote(str(value))}")


def parse_manifest_projects(root: Path) -> dict[str, list[str]]:
    projects: dict[str, list[str]] = {}
    manifest_root = root / ".repo" / "manifests"
    candidates = []
    if (root / ".repo" / "manifest.xml").is_file():
        candidates.append(root / ".repo" / "manifest.xml")
    if (manifest_root / "default.xml").is_file():
        candidates.append(manifest_root / "default.xml")
    local_manifest_dir = root / ".repo" / "local_manifests"
    if local_manifest_dir.is_dir():
        candidates.extend(sorted(local_manifest_dir.glob("*.xml")))

    seen: set[Path] = set()

    def parse_one(path: Path) -> None:
        path = path.resolve()
        if path in seen or not path.is_file():
            return
        seen.add(path)
        try:
            tree = ET.parse(path)
        except ET.ParseError:
            return
        elem = tree.getroot()
        for include in elem.findall("include"):
            name = include.get("name")
            if name:
                parse_one(manifest_root / name)
        for project in elem.findall("project"):
            name = project.get("name")
            if not name:
                continue
            relpath = project.get("path") or name
            projects.setdefault(name, [])
            if relpath not in projects[name]:
                projects[name].append(relpath)

    for candidate in candidates:
        parse_one(candidate)
    return projects


def repo_paths(root: Path, repo_name: str) -> tuple[str, ...]:
    paths: list[str] = []
    for relpath in parse_manifest_projects(root).get(repo_name, []):
        if relpath not in paths:
            paths.append(relpath)
    for relpath in FALLBACK_REPO_PATHS.get(repo_name, ()):
        if relpath not in paths:
            paths.append(relpath)
    return tuple(paths)


def checkout_plan(meta: dict[str, Any], root: Path) -> list[tuple[str, str, str]]:
    plan: list[tuple[str, str, str]] = []
    for repo_name, commit in meta.get("repo_commits", {}).items():
        if not commit:
            continue
        for relpath in repo_paths(root, repo_name):
            if git_head(root / relpath):
                plan.append((repo_name, relpath, commit))
                break
    return plan


def git_head(path: Path) -> str:
    if not path.is_dir():
        return ""
    try:
        top = subprocess.check_output(
            ["git", "-C", str(path), "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
        if Path(top).resolve() != path.resolve():
            return ""
        return subprocess.check_output(
            ["git", "-C", str(path), "rev-parse", "HEAD"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return ""


def verify_checkout(meta: dict[str, Any], root: Path, required: list[str]) -> int:
    repo_commits = meta.get("repo_commits", {})
    errors: list[str] = []
    for repo_name in required:
        expected = repo_commits.get(repo_name, "")
        if not expected:
            errors.append(
                f"missing BUILD_INFO commit for {repo_name}; rerun prepare.sh after "
                "updating this workflow, or provide a CI build id whose BUILD_INFO is accessible"
            )
            continue
        found_path = ""
        actual = ""
        paths = repo_paths(root, repo_name)
        for relpath in paths:
            actual = git_head(root / relpath)
            if actual:
                found_path = relpath
                break
        if not actual:
            errors.append(f"missing git project checkout for {repo_name} at {paths}")
            continue
        if actual != expected:
            errors.append(f"{repo_name} ({found_path}) is {actual[:12]}, expected {expected[:12]}")
        else:
            print(f"[OK] {repo_name} ({found_path}) = {actual[:12]}")

    if errors:
        print("ERROR: kernel source checkout is not aligned with target BUILD_INFO:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        return 1
    return 0


def cmd_parse(args: argparse.Namespace) -> int:
    meta = parse_proc_version(read_proc_version(args))
    if args.format == "env":
        emit_env({"repo_commits": {"kernel/common": meta["common_commit_from_proc"]}, **meta})
    else:
        print(json.dumps(meta, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


def cmd_metadata(args: argparse.Namespace) -> int:
    meta = build_metadata(args)
    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(meta, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.env_out:
        env_out = Path(args.env_out)
        env_out.parent.mkdir(parents=True, exist_ok=True)
        with env_out.open("w", encoding="utf-8") as fh:
            old_stdout = sys.stdout
            try:
                sys.stdout = fh
                emit_env(meta)
            finally:
                sys.stdout = old_stdout
    if not args.quiet:
        print(json.dumps(meta, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


def cmd_env(args: argparse.Namespace) -> int:
    meta = json.loads(Path(args.meta).read_text(encoding="utf-8"))
    emit_env(meta)
    return 0


def cmd_checkout_plan(args: argparse.Namespace) -> int:
    meta = json.loads(Path(args.meta).read_text(encoding="utf-8"))
    root = Path(args.root).resolve()
    for repo_name, relpath, commit in checkout_plan(meta, root):
        print(f"{repo_name}\t{relpath}\t{commit}")
    return 0


def cmd_verify_checkout(args: argparse.Namespace) -> int:
    meta = json.loads(Path(args.meta).read_text(encoding="utf-8"))
    root = Path(args.root).resolve()
    return verify_checkout(meta, root, args.required)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    parse_p = sub.add_parser("parse")
    parse_p.add_argument("--proc-version")
    parse_p.add_argument("--proc-version-file")
    parse_p.add_argument("--format", choices=("json", "env"), default="json")
    parse_p.set_defaults(func=cmd_parse)

    meta_p = sub.add_parser("metadata")
    meta_p.add_argument("--proc-version")
    meta_p.add_argument("--proc-version-file")
    meta_p.add_argument("--build-id")
    meta_p.add_argument("--repo-branch")
    meta_p.add_argument("--kernel-version")
    meta_p.add_argument("--common-commit")
    meta_p.add_argument("--ci-target", default="kernel_virt_x86_64")
    meta_p.add_argument("--out")
    meta_p.add_argument("--env-out")
    meta_p.add_argument("--quiet", action="store_true")
    meta_p.set_defaults(func=cmd_metadata)

    env_p = sub.add_parser("env")
    env_p.add_argument("--meta", required=True)
    env_p.set_defaults(func=cmd_env)

    plan_p = sub.add_parser("checkout-plan")
    plan_p.add_argument("--meta", required=True)
    plan_p.add_argument("--root", default=os.getcwd())
    plan_p.set_defaults(func=cmd_checkout_plan)

    verify_p = sub.add_parser("verify-checkout")
    verify_p.add_argument("--meta", required=True)
    verify_p.add_argument("--root", default=os.getcwd())
    verify_p.add_argument("--required", action="append", required=True)
    verify_p.set_defaults(func=cmd_verify_checkout)

    return args_func(parser.parse_args())


def args_func(args: argparse.Namespace) -> int:
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
