#!/usr/bin/env python3
"""Parse AVD kernel versions and produce reproducible build metadata."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sys
import urllib.error
import urllib.request
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

REPO_PATHS = {
    "kernel/common": ("common",),
    "kernel/common-modules/virtual-device": ("common-modules/virtual-device",),
    "kernel/build": ("build/kernel", "build"),
    "kernel/configs": ("kernel/configs",),
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


def fetch_json_url(url: str) -> dict[str, Any]:
    with urllib.request.urlopen(url, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


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
    build_info: dict[str, Any] | None = None
    ci_error = ""
    if build_id:
        build_info_url = (
            f"https://ci.android.com/builds/submitted/{build_id}/"
            f"{ci_target}/latest/view/BUILD_INFO"
        )
        try:
            build_info = fetch_json_url(build_info_url)
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


def checkout_plan(meta: dict[str, Any], root: Path) -> list[tuple[str, str, str]]:
    plan: list[tuple[str, str, str]] = []
    for repo_name, commit in meta.get("repo_commits", {}).items():
        if not commit or repo_name not in REPO_PATHS:
            continue
        for relpath in REPO_PATHS[repo_name]:
            if (root / relpath).is_dir():
                plan.append((repo_name, relpath, commit))
                break
    return plan


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

    return args_func(parser.parse_args())


def args_func(args: argparse.Namespace) -> int:
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
