#!/usr/bin/env python3
"""Emit key=value facts about a TOML file, for the shell cases to assert on.

Usage: facts.py manifest <path>
       facts.py config   <path>

Exits non-zero if the file is missing or not valid TOML, which is itself a
test failure the caller reports.
"""

import sys
import tomllib


def emit(key, value):
    print(f"{key}={value}")


def load(path):
    with open(path, "rb") as fh:
        return tomllib.load(fh)


def manifest(path):
    doc = load(path)
    emit("valid_toml", 1)

    boot = doc.get("bootstrap", {})
    services = boot.get("services", {})
    emit("service_builtin", services.get("mise-history", {}).get("builtin", ""))

    repos = boot.get("repos", {})
    emit("repos_count", len(repos))
    for key, value in repos.items():
        emit("repo", f"{key} {value.get('url', '')}")

    packages = boot.get("packages", {})
    emit("packages_count", len(packages))
    emit("packages_all_pacman", int(all(k.startswith("pacman:") for k in packages)))


def config(path):
    doc = load(path)
    emit("valid_toml", 1)

    excludes = doc.get("history", {}).get("exclude", [])
    emit("exclude_count", len(excludes))
    emit("exclude_unique", len(set(excludes)))

    tracked = doc.get("dotfiles", {})
    if isinstance(tracked, dict):
        paths = tracked.get("paths", tracked.get("track", []))
    else:
        paths = tracked
    emit("dotfiles_count", len(paths) if hasattr(paths, "__len__") else 0)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    {"manifest": manifest, "config": config}[sys.argv[1]](sys.argv[2])
