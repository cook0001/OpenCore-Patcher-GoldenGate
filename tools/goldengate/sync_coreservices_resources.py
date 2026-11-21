#!/usr/bin/env python3
"""Package or sync donor macOS 26 (25G342) UI resources for bridged CoreServices apps."""

import argparse
from pathlib import Path
import tarfile

CORESERVICES_25G342_APPS = (
    "AirPlayUIAgent.app",
    "ControlCenter.app",
    "CoreServicesUIAgent.app",
    "Dock.app",
    "Finder.app",
    "NotificationCenter.app",
    "Setup Assistant.app",
    "Spotlight.app",
    "SystemUIServer.app",
    "UserNotificationCenter.app",
    "WallpaperAgent.app",
    "WindowManager.app",
    "loginwindow.app",
)

RESOURCE_SUFFIXES = (".nib", ".storyboardc", ".loctable", ".strings")
LOCALIZATION_DIRS = ("Base.lproj", "en.lproj")


def collect_resource_paths(source_root: Path) -> list[Path]:
    collected: list[Path] = []
    cs_root = source_root / "System" / "Library" / "CoreServices"
    for app_name in CORESERVICES_25G342_APPS:
        res_dir = cs_root / app_name / "Contents" / "Resources"
        if not res_dir.is_dir():
            continue
        scan_dirs = [res_dir] + [res_dir / loc for loc in LOCALIZATION_DIRS if (res_dir / loc).is_dir()]
        for d in scan_dirs:
            for entry in sorted(d.iterdir()):
                if entry.suffix in RESOURCE_SUFFIXES:
                    collected.append(entry)
    return collected


def build_archive(source_root: Path, archive_path: Path) -> int:
    paths = collect_resource_paths(source_root)
    with tarfile.open(archive_path, "w:gz") as tf:
        for path in paths:
            arcname = path.relative_to(source_root).as_posix()
            tf.add(path, arcname=arcname)
    return len(paths)


def main() -> int:
    parser = argparse.ArgumentParser(description="Archive 25G342 CoreServices nib/loctable resources.")
    parser.add_argument("--source-root", type=Path, default=Path("/"), help="Root of donor macOS 26 (25G342) volume")
    parser.add_argument("--output", type=Path, required=True, help="Output .tgz path")
    args = parser.parse_args()
    count = build_archive(args.source_root, args.output)
    print(f"Archived {count} resource items to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
