"""Inert, physical installed-input inventory; never a game launcher.

The protected scope is deliberately broader than the ten launch roles. Mutable
context and opaque VFS providers are observations, not immutable input claims.
Directory membership checkpoints do not seal a namespace against later writes.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import ntpath
import os
from pathlib import Path
import re
import stat


SCOPE = "beamrt-installed-source-coverage-v1"
MAX_RECORDS = 16384
MAX_FILES = 8192
MAX_FILE_BYTES = 1024 ** 3
MAX_TOTAL_BYTES = 2 * 1024 ** 3
ARTIFACT_ROLES = frozenset(("host", "dll", "vertex", "pixel", "decoder"))
EXCLUDED_CONTROL_DIRECTORIES = frozenset((".git", ".beamrt-validation", ".vscode", ".github", "__pycache__"))
_HEX = re.compile(r"[0-9a-f]{64}")
_DEVICE = re.compile(r"CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³]", re.I)


def canonical_path(value):
    if type(value) is not str or not re.match(r"^[A-Za-z]:[\\/]", value) or len(value) > 32700:
        raise ValueError("explicit bounded drive-absolute physical path required")
    value = value.replace("/", "\\")
    if len(value) <= 3 or any(not part or part in (".", "..") or part.endswith((" ", ".")) or
            any(ord(c) < 32 or c in '<>:"|?*' for c in part) or _DEVICE.fullmatch(part.split(".", 1)[0])
            for part in value[3:].split("\\")):
        raise ValueError("ambiguous, device, stream or root path refused")
    value.encode("utf-16-le", "strict")
    return value[0].upper() + value[1:]


def _exact(value, keys):
    if type(value) is not dict or set(value) != set(keys):
        raise ValueError("exact installed-coverage schema required")


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
                      allow_nan=False).encode("ascii")


def build_spec(beamrt_root, engine_root, user_root, artifacts):
    """Pure explicit paths/pins only. No reads, writes, locks or execution."""
    roots = {name: canonical_path(value) for name, value in
             (("beamrt", beamrt_root), ("engine", engine_root), ("user", user_root))}
    if roots["beamrt"].casefold() != ntpath.join(roots["user"], "mods", "unpacked", "beamrt").casefold():
        raise ValueError("actual installed unpacked BeamRT/user-root join required")
    if roots["engine"].casefold().startswith(roots["user"].casefold() + "\\") or \
            roots["user"].casefold().startswith(roots["engine"].casefold() + "\\") or \
            roots["engine"].casefold() == roots["user"].casefold():
        raise ValueError("engine and user roots must be distinct non-overlapping installations")
    _exact(artifacts, ARTIFACT_ROLES)
    declared, seen = {}, set()
    for role in sorted(ARTIFACT_ROLES):
        entry = artifacts[role]
        _exact(entry, ("path", "sha256"))
        path = canonical_path(entry["path"])
        if type(entry["sha256"]) is not str or not _HEX.fullmatch(entry["sha256"]):
            raise ValueError("explicit lowercase native-artifact SHA256 required")
        expected = {"host": "beamrt_startup_host.exe", "dll": "beamrt_startup_bootstrap.dll",
                    "decoder": "receipt_decoder.exe"}.get(role)
        if expected and ntpath.basename(path) != expected or role in ("vertex", "pixel") and not path.endswith(".cso"):
            raise ValueError("unexpected observation artifact leaf")
        if path.casefold() in seen:
            raise ValueError("native artifact roles alias")
        seen.add(path.casefold())
        declared[role] = {"path": path, "sha256": entry["sha256"]}
    return {"schema": 1, "scope": SCOPE, "roots": roots, "artifacts": declared}


def _validate_spec(spec):
    _exact(spec, ("schema", "scope", "roots", "artifacts"))
    _exact(spec["roots"], ("beamrt", "engine", "user"))
    if type(spec["schema"]) is not int or spec["schema"] != 1 or spec["scope"] != SCOPE:
        raise ValueError("unsupported installed-coverage schema/scope")
    checked = build_spec(spec["roots"]["beamrt"], spec["roots"]["engine"], spec["roots"]["user"], spec["artifacts"])
    if spec != checked:
        raise ValueError("noncanonical coverage specification")
    return checked


def _critical_members(spec):
    """Known installed entry/control files; not an executed dependency graph."""
    result = [ntpath.join(spec["roots"]["beamrt"], *path.split("/")) for path in
              ("lua/ge/extensions/beamrt/main.lua", "scripts/beamrt/modScript.lua")]
    result += [ntpath.join(spec["roots"]["engine"], *path.split("/")) for path in (
        "Bin64/BeamNG.drive.x64.exe", "Bin64/binaryDependencies.json", "lua/ge/main.lua",
        "lua/ge/client/parseArgs.lua", "lua/ge/client/core.lua", "lua/ge/client/init.lua",
        "lua/common/extensions.lua", "lua/common/luaCore.lua", "lua/common/utils.lua", "lua/common/json.lua",
        "lua/ge/extensions/core/levels.lua", "lua/ge/extensions/core/gamestate.lua",
        "lua/ge/extensions/core/modmanager.lua", "lua/ge/extensions/core/loadMapCmd.lua",
        "lua/ge/extensions/core/settings/settings.lua", "lua/ge/extensions/core/settings/graphic.lua",
        "lua/ge/extensions/freeroam/freeroam.lua")]
    return result


def _group_specs(spec):
    roots = spec["roots"]
    groups = []

    def add(name, category, path, *, kind="directory", recursive=True, required=True,
            exclude_bytecode=False, exclude_logs=False, exclude_controls=False):
        groups.append({"name": name, "category": category, "path": path, "kind": kind,
            "recursive": recursive, "required": required, "exclude_bytecode": exclude_bytecode,
            "exclude_logs": exclude_logs, "exclude_controls": exclude_controls})

    # Whole physical mod tree: does not obey .gitignore and does not assume that
    # autoloadable files can exist only in the four currently known subtrees.
    add("installed-beamrt", "protected", roots["beamrt"], exclude_bytecode=True, exclude_controls=True)
    for name in ("lua", "shaders", "Bin64", "settings"):
        add("engine-" + name, "protected", ntpath.join(roots["engine"], name), exclude_logs=name == "Bin64")
    for name in ("gameengine.zip", "shaders.7z", "startup.ini", "startup.default.ini"):
        add("engine-" + name, "protected", ntpath.join(roots["engine"], name), kind="file")
    for role, entry in sorted(spec["artifacts"].items()):
        add("native-" + role, "protected", entry["path"], kind="file")
    # These are normal game write targets. They are never in protection_manifest.
    add("user-settings", "mutable-context", ntpath.join(roots["user"], "settings"))
    add("user-mod-database", "mutable-context", ntpath.join(roots["user"], "mods", "db.json"), kind="file")
    add("user-shader-cache", "mutable-context", ntpath.join(roots["user"], "temp", "shaders"), required=False)
    for name in ("lua", "shaders", "scripts", "art", "levels", "vehicles"):
        add("user-override-" + name, "opaque-context", ntpath.join(roots["user"], name),
            recursive=False, required=False)
    for name in ("", "repo", "unpacked", "multiplayer"):
        add("mod-providers-" + (name or "root"), "opaque-context", ntpath.join(roots["user"], "mods", name).rstrip("\\"),
            recursive=False, required=not name)
    for name in ("content/levels/west_coast_usa.zip", "content/vehicles/common.zip"):
        add("scene-" + ntpath.basename(name), "opaque-context",
            ntpath.join(roots["engine"], name.replace("/", "\\")), kind="file")
    return groups


def _information(path):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
        raise ValueError("physical coverage refuses links/reparse points")
    if not stat.S_ISDIR(info.st_mode) and not stat.S_ISREG(info.st_mode):
        raise ValueError("unexpected physical coverage input type")
    return info


def _hash_file(path, expected):
    if not 0 <= expected.st_size <= MAX_FILE_BYTES:
        raise ValueError("protected/snapshotted file exceeds unchanged per-file budget")
    digest, consumed = hashlib.sha256(), 0
    with path.open("rb") as stream:
        opened = os.fstat(stream.fileno())
        if (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns) != \
                (expected.st_dev, expected.st_ino, expected.st_size, expected.st_mtime_ns):
            raise ValueError("input identity changed before inventory read")
        while True:
            image = stream.read(1024 * 1024)
            if not image:
                break
            consumed += len(image)
            if consumed > expected.st_size:
                raise ValueError("input grew during inventory read")
            digest.update(image)
        after = os.fstat(stream.fileno())
        current = _information(path)
        identity = lambda item: (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns)
        if consumed != expected.st_size or identity(after) != identity(expected) or identity(current) != identity(expected):
            raise ValueError("input changed during inventory read")
    return digest.hexdigest()


def _scan_tree(path, recursive=True, exclude_bytecode=False, exclude_logs=False, with_hash=True,
               *, required=True, exclude_controls=False):
    """Physical enumeration, including empty directories; no gitignore/VFS rules.

    This low-level scanner is portable for disposable filesystem tests. Public
    specifications and serialized snapshots still require canonical Windows paths.
    """
    path = Path(path)
    # Inspect every physical ancestor rather than following an unnoticed parent
    # junction. The later lease independently verifies retained Win32 identities.
    for ancestor in reversed((path, *path.parents)):
        try:
            _information(ancestor)
        except FileNotFoundError:
            if not required:
                return [{"path": str(path), "kind": "absent", "size": 0, "mtime_ns": 0, "sha256": None}]
            raise
    records, pending = [], [path]
    while pending:
        item = pending.pop()
        info = _information(item)
        directory = stat.S_ISDIR(info.st_mode)
        records.append({"path": str(item), "kind": "directory" if directory else "file",
            "size": 0 if directory else info.st_size, "mtime_ns": info.st_mtime_ns,
            "sha256": _hash_file(item, info) if with_hash and not directory else None})
        if len(records) > MAX_RECORDS:
            raise ValueError("physical group inventory exceeded record budget")
        if directory and (recursive or item == path):
            children = []
            with os.scandir(item) as entries:
                for entry in entries:
                    name = entry.name.casefold()
                    if exclude_bytecode and (name == "__pycache__" or
                            name.endswith((".pyc", ".pyo")) and entry.is_file(follow_symlinks=False)):
                        continue
                    if exclude_logs and name.endswith(".log") and entry.is_file(follow_symlinks=False):
                        continue
                    if exclude_controls and name in EXCLUDED_CONTROL_DIRECTORIES:
                        continue
                    children.append(Path(entry.path))
                    if len(children) + len(records) > MAX_RECORDS:
                        raise ValueError("physical directory exceeded record budget")
            for child in sorted(children, key=lambda value: str(value).casefold(), reverse=True):
                if recursive or item == path:
                    pending.append(child)
            # In shallow mode, do not descend through immediate child dirs.
            if not recursive:
                for child in pending:
                    child_info = _information(child)
                    child_dir = stat.S_ISDIR(child_info.st_mode)
                    records.append({"path": str(child), "kind": "directory" if child_dir else "file",
                        "size": 0 if child_dir else child_info.st_size, "mtime_ns": child_info.st_mtime_ns,
                        "sha256": _hash_file(child, child_info) if with_hash and not child_dir else None})
                pending.clear()
    records.sort(key=lambda value: value["path"].casefold())
    if len({value["path"].casefold() for value in records}) != len(records):
        raise ValueError("case-aliased physical inventory paths")
    return records


def _scan_group(group, *, hash_protected=True, hash_context=True):
    records = _scan_tree(group["path"], group["recursive"], group["exclude_bytecode"], group["exclude_logs"],
        with_hash=hash_context and group["category"] == "mutable-context" or hash_protected and group["category"] == "protected",
        required=group["required"], exclude_controls=group["exclude_controls"])
    root = next((record for record in records if record["path"].casefold() == group["path"].casefold()), None)
    if root is None or root["kind"] != group["kind"] and not (root["kind"] == "absent" and not group["required"]):
        raise ValueError("declared coverage root has wrong physical type")
    return {**group, "records": records}


def collect(spec):
    checked = _validate_spec(spec)
    groups = [_scan_group(group, hash_protected=False, hash_context=False) for group in _group_specs(checked)]
    # Check the entire selected read budget BEFORE hashing. An oversized engine
    # or mutable cache must not consume unbounded I/O before a later refusal.
    hashed = [record for group in groups if group["category"] != "opaque-context"
              for record in group["records"] if record["kind"] == "file"]
    if sum(len(group["records"]) for group in groups) > MAX_RECORDS or len(hashed) > MAX_FILES or \
            any(record["size"] > MAX_FILE_BYTES for record in hashed) or \
            sum(record["size"] for record in hashed) > MAX_TOTAL_BYTES:
        raise ValueError("complete inventory hash-read budget exceeded before file reads")
    for record in hashed:
        path = Path(record["path"])
        info = _information(path)
        if info.st_size != record["size"] or info.st_mtime_ns != record["mtime_ns"]:
            raise ValueError("input changed between inventory enumeration and hashing")
        record["sha256"] = _hash_file(path, info)
    snapshot = {"schema": 1, "scope": SCOPE, "spec": checked, "groups": groups}
    snapshot["coverageSHA256"] = hashlib.sha256(_canonical(snapshot)).hexdigest()
    validate_snapshot(snapshot)
    for role, entry in checked["artifacts"].items():
        group = next(group for group in groups if group["name"] == "native-" + role)
        if group["records"][0]["sha256"] != entry["sha256"]:
            raise ValueError("native artifact differs from its explicitly reviewed pin")
    return snapshot


def validate_snapshot(snapshot):
    _exact(snapshot, ("schema", "scope", "spec", "groups", "coverageSHA256"))
    if type(snapshot["schema"]) is not int or snapshot["schema"] != 1 or snapshot["scope"] != SCOPE:
        raise ValueError("unsupported coverage snapshot")
    spec = _validate_spec(snapshot["spec"])
    expected_groups = _group_specs(spec)
    if type(snapshot["groups"]) is not list or len(snapshot["groups"]) != len(expected_groups):
        raise ValueError("missing/extra installed coverage group")
    total = 0
    for group, expected in zip(snapshot["groups"], expected_groups):
        _exact(group, (*expected, "records"))
        if _canonical({key: group[key] for key in expected}) != _canonical(expected) or type(group["records"]) is not list or not group["records"]:
            raise ValueError("coverage policy changed or group omitted")
        seen, roots = set(), 0
        for record in group["records"]:
            _exact(record, ("path", "kind", "size", "mtime_ns", "sha256"))
            path = canonical_path(record["path"])
            if path != record["path"] or not (path.casefold() == group["path"].casefold() or
                    group["kind"] == "directory" and path.casefold().startswith(group["path"].casefold() + "\\")):
                raise ValueError("coverage record escapes its physical root")
            if path.casefold() in seen:
                raise ValueError("duplicate/case-alias coverage record")
            seen.add(path.casefold())
            roots += path.casefold() == group["path"].casefold()
            if record["kind"] not in ("file", "directory", "absent") or any(type(record[key]) is not int or
                    record[key] < 0 for key in ("size", "mtime_ns")):
                raise ValueError("coverage metadata type/value refused")
            if record["kind"] == "absent" and (group["required"] or path != group["path"] or len(group["records"]) != 1):
                raise ValueError("unsupported coverage absence")
            hashed = record["kind"] == "file" and group["category"] != "opaque-context"
            if hashed and (type(record["sha256"]) is not str or not _HEX.fullmatch(record["sha256"])) or \
                    not hashed and record["sha256"] is not None or record["kind"] != "file" and record["size"] != 0:
                raise ValueError("coverage record digest/size refused")
        if roots != 1:
            raise ValueError("coverage group root record missing")
        root = next(record for record in group["records"] if record["path"] == group["path"])
        if root["kind"] != group["kind"] and not (root["kind"] == "absent" and not group["required"]):
            raise ValueError("serialized coverage root has wrong physical type")
        if group["category"] == "protected" and group["name"].startswith("native-"):
            role = group["name"][len("native-"):]
            if root["sha256"] != spec["artifacts"][role]["sha256"]:
                raise ValueError("serialized native artifact disagrees with its reviewed pin")
        total += len(group["records"])
    if total > MAX_RECORDS:
        raise ValueError("complete coverage snapshot exceeds record budget")
    base = {key: value for key, value in snapshot.items() if key != "coverageSHA256"}
    if type(snapshot["coverageSHA256"]) is not str or snapshot["coverageSHA256"] != hashlib.sha256(_canonical(base)).hexdigest():
        raise ValueError("coverage snapshot digest mismatch")
    manifest = protection_manifest(snapshot, _validated=True)
    held_paths = {path.casefold() for path in manifest}
    if any(path.casefold() not in held_paths for path in _critical_members(spec)):
        raise ValueError("known installed renderer/engine entry-control input is missing")
    return True


def protection_manifest(snapshot, *, _validated=False):
    if not _validated:
        validate_snapshot(snapshot)
    manifest, identities, total = {}, set(), 0
    for group in snapshot["groups"]:
        if group["category"] != "protected":
            continue
        for record in group["records"]:
            if record["kind"] == "file":
                key = record["path"].casefold()
                if key in identities:
                    raise ValueError("protected groups have overlapping/case-aliased files")
                identities.add(key)
                if record["size"] > MAX_FILE_BYTES:
                    raise ValueError("protected input exceeds unchanged per-file budget")
                total += record["size"]
                manifest[record["path"]] = record["sha256"]
    if not manifest or len(manifest) > MAX_FILES or total > MAX_TOTAL_BYTES:
        raise ValueError("bounded complete protected source scope exceeded")
    return manifest


def checkpoint(snapshot):
    """Refuse membership/type/size/time/context drift at this checkpoint only.

    Protected file contents are verified by the retained-handle lease, not by
    path reopens here. Mutable context is rehashed without deny-write locks.
    """
    validate_snapshot(snapshot)
    for before in snapshot["groups"]:
        group = {key: value for key, value in before.items() if key != "records"}
        after = _scan_group(group, hash_protected=False)
        expected = [{**record, "sha256": None} if group["category"] == "protected" else record
                    for record in before["records"]]
        if after["records"] != expected:
            raise ValueError("installed input/context inventory drift: " + group["name"])
    return True


def report(snapshot):
    validate_snapshot(snapshot)
    groups = [{"name": group["name"], "category": group["category"],
               "files": sum(record["kind"] == "file" for record in group["records"]),
               "bytes": sum(record["size"] for record in group["records"])} for group in snapshot["groups"]]
    return {"scope": SCOPE, "coverageSHA256": snapshot["coverageSHA256"], "groups": groups,
        "protectedFiles": len(protection_manifest(snapshot)),
        "protectedBytes": sum(group["bytes"] for group in groups if group["category"] == "protected"),
        "mutableContextHeld": False, "namespaceSealed": False, "fullEnvironmentProtected": False,
        "gameExecutionAvailable": False,
        "remaining": ["mounted VFS winners and future namespace additions are not certified",
            "other mod/provider and complete scene/vehicle bytes are not protected",
            "mutable settings/mod database/shader caches are snapshots, not locks",
            "compatibility of held generated assets with future game writes is not established",
            "dynamic OS/driver dependencies and queued-Lua startup ordering remain unverified"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError("duplicate input coverage JSON key")
            value[key] = item
        return value
    with args.spec.open("rb") as stream:
        image = stream.read(65537)
    if not image or len(image) > 65536:
        raise ValueError("bounded explicit coverage specification required")
    spec = json.loads(image.decode("utf-8"), object_pairs_hook=unique)
    snapshot = collect(spec)
    if args.output:
        with args.output.open("xb") as stream:
            stream.write(_canonical(snapshot) + b"\n")
    print(json.dumps(report(snapshot), indent=2))


if __name__ == "__main__":
    main()
