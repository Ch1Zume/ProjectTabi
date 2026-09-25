"""Generate update metadata from the exact release artifacts, never from mutable URLs."""
import argparse
import hashlib
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote


def version():
    match = re.search(r"^version: (\d+\.\d+\.\d+)\+(\d+)\s*$", Path("pubspec.yaml").read_text(encoding="utf-8"), re.M)
    if not match:
        raise SystemExit("pubspec.yaml must contain version: major.minor.patch+build")
    return match.group(1), int(match.group(2))


def notes(name):
    text = Path("PATCH_NOTES.md").read_text(encoding="utf-8")
    match = re.search(rf"^## {re.escape(name)}\b[^\n]*\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    if not match:
        raise SystemExit(f"Missing patch notes for {name}")
    return match.group(1).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--assets", type=Path)
    parser.add_argument("--tag", default=os.environ.get("GITHUB_REF_NAME", ""))
    args = parser.parse_args()
    name, build = version()
    full_version = f"{name}+{build}"
    if args.tag.startswith("v") and args.tag not in (f"v{name}", f"v{name}-build.{build}"):
        raise SystemExit("Release tag must match the app version and build number")
    tauri = json.loads(Path("src-tauri/tauri.conf.json").read_text(encoding="utf-8"))
    if tauri["version"] != full_version:
        raise SystemExit("Tauri and Flutter version/build must match")
    stem = f"ProjectTabi-v{name}-build.{build}"
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a", encoding="utf-8") as stream:
            stream.write(f"stem={stem}\nversion={name}\nbuild={build}\n")
    if not args.assets:
        return
    if not args.tag.startswith("v"):
        raise SystemExit("A release tag is required for update URLs")
    root = "https://github.com/Ch1Zume/ProjectTabi/releases/download/" + quote(args.tag, safe="") + "/"
    def asset(file_name):
        path = args.assets / file_name
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for data in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(data)
        return {"url": root + quote(file_name, safe=""), "size": path.stat().st_size, "sha256": digest.hexdigest()}
    windows = asset(stem + "-windows-setup.exe")
    windows["signature"] = (args.assets / (stem + "-windows-setup.exe.sig")).read_text(encoding="utf-8").strip()
    if not windows["signature"]:
        raise SystemExit("Missing Windows update signature")
    android = asset(stem + ".apk")
    android.update(versionCode=build, versionName=name)
    changelog = notes(name)
    manifest = {"version": full_version, "notes": changelog,
                "pub_date": datetime.now(timezone.utc).isoformat(),
                "platforms": {"windows-x86_64": windows}, "android": android}
    (args.assets / "latest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    Path("RELEASE_NOTES.md").write_text(
        f"## ProjectTabi {name} · 构建 {build}\n\n" + changelog +
        "\n\n已安装 0.1.1（构建 3）或更新版本的用户，可通过“设置 → 关于 ProjectTabi → 应用更新”下载安装；更早版本需先手动覆盖安装。\n",
        encoding="utf-8")


if __name__ == "__main__":
    main()
