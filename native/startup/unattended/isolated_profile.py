"""Prepare a fresh BeamRT-only user tree; never start or configure BeamNG.

Imports are inert. Preparation needs explicit frozen-source-loaded file-lock
dependencies. It copies held bytes to new files, not links or path-reopened
sources. A receipt describes a disk checkpoint, not runtime/VFS/cloud isolation.
Partial attempts are retained and cannot be resumed or overwritten.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys


SCHEMA = "beamrt-isolated-profile-v1"
MAX_FILES = 512
MAX_DIRECTORIES = 512
MAX_FILE_BYTES = 32 * 1024 ** 2
MAX_TOTAL_BYTES = 128 * 1024 ** 2
RUNTIME_ROOTS = ("art", "lua", "scripts", "shaders")
RUNTIME_PREFIXES = {"art": "beamrt", "lua": "ge/extensions/beamrt",
                    "scripts": "beamrt", "shaders": "beamrt"}
SUFFIXES = {"art": {".json", ".png", ".dds"}, "lua": {".lua"},
            "scripts": {".lua"}, "shaders": {".hlsl", ".json", ".png", ".dds"}}
CONTROLS = ("early_shim.lua", "bootstrap.lua", "engine_adapter.lua", "controller.lua")
PROTECTED_SOURCE_SHA256 = "d6c95facda3589ef01e963136b652a0c40e30496d2499e13bf135cad3dcba64a"
MOD_DESTINATION = "user/current/mods/unpacked/beamrt"
EMPTY_DIRECTORIES = ("user/current/settings", "user/current/temp/shaders")
PLAN_LEAF = "profile-plan.json"
RECEIPT_LEAF = "profile-receipt.json"
_DEVICE = re.compile(r"(?:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])(?:\..*)?", re.I)


def _component(value):
    if not value or value in (".", "..") or value[-1:] in (" ", ".") \
            or any(ord(c) < 32 or c in '<>:"|?*\\/' for c in value) \
            or _DEVICE.fullmatch(value):
        raise ValueError("ambiguous physical path component refused")


def _path(value):
    raw = os.fspath(value)
    if not isinstance(raw, str) or not raw or len(raw) >= 260:
        raise ValueError("bounded physical path required")
    path = Path(raw)
    if not path.is_absolute() or (os.name == "nt" and
            (not re.match(r"^[A-Za-z]:[\\/]", raw) or raw.startswith("\\\\"))):
        raise ValueError("absolute local physical path required")
    # Check before pathlib can normalize dot or empty interior components.
    tail = raw[len(path.anchor):].replace("\\", "/")
    for component in tail.split("/"):
        _component(component)
    return path


def _physical(path, *, directory):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
        raise ValueError("symlink or reparse point refused")
    if (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)) is not True:
        raise ValueError("unexpected physical file type refused")
    if not directory and info.st_nlink != 1:
        raise ValueError("hardlinked source or destination refused")
    return info


def _ancestors(path):
    return tuple(reversed(path.parents)) + (path,)


def _physical_directory(path):
    for item in _ancestors(path):
        _physical(item, directory=True)


def _overlap(first, second):
    a, b = str(first).replace("\\", "/").casefold(), str(second).replace("\\", "/").casefold()
    return a == b or a.startswith(b.rstrip("/") + "/") or b.startswith(a.rstrip("/") + "/")


def _roots(source_mod_root, profile_root, engine_root, *, fresh):
    source, profile, engine = map(_path, (source_mod_root, profile_root, engine_root))
    if tuple(part.casefold() for part in source.parts[-3:]) != ("mods", "unpacked", "beamrt"):
        raise ValueError("source must be the explicit mods/unpacked/beamrt directory")
    normal = source.parents[2]
    if not re.fullmatch(r"beamrt-profile-[0-9a-f]{12,32}", profile.name):
        raise ValueError("fresh explicitly named beamrt-profile token required")
    if not str(profile).isascii() or any(c.isspace() for c in str(profile)):
        raise ValueError("profile path must be short ASCII without whitespace")
    if any(_overlap(a, b) for a, b in ((normal, engine), (normal, profile), (engine, profile))):
        raise ValueError("profile, normal user tree, and engine must be disjoint")
    _physical_directory(source)
    _physical_directory(engine)
    _physical_directory(profile.parent)
    if fresh and os.path.lexists(profile):
        raise FileExistsError("profile destination already exists; no reuse or overwrite")
    if not fresh:
        _physical_directory(profile)
    return source, profile, engine, normal


def _inventory(root):
    """Enumerate physical membership, including empty directories and ignored files."""
    files, directories, seen = [], [], set()

    def visit(directory, depth):
        if depth > 32:
            raise ValueError("profile directory depth exceeded")
        _physical(directory, directory=True)
        with os.scandir(directory) as entries:
            children = []
            for entry in entries:
                children.append(entry)
                if len(children) > MAX_FILES + MAX_DIRECTORIES:
                    raise ValueError("profile immediate namespace budget exceeded")
        children.sort(key=lambda entry: entry.name.casefold())
        for entry in children:
            _component(entry.name)
            path = directory / entry.name
            _path(path)
            relative = path.relative_to(root).as_posix()
            key = relative.casefold()
            if key in seen:
                raise ValueError("case-alias namespace member refused")
            seen.add(key)
            info = entry.stat(follow_symlinks=False)
            if stat.S_ISDIR(info.st_mode):
                _physical(path, directory=True)
                directories.append(relative)
                if len(directories) > MAX_DIRECTORIES:
                    raise ValueError("profile directory budget exceeded")
                visit(path, depth + 1)
            else:
                info = _physical(path, directory=False)
                files.append((relative, info))
                if len(files) > MAX_FILES:
                    raise ValueError("profile file budget exceeded")

    visit(root, 0)
    return files, sorted(directories)


def _record(path, destination):
    before = _physical(path, directory=False)
    if not 0 <= before.st_size <= MAX_FILE_BYTES:
        raise ValueError("profile per-file byte budget exceeded")
    digest = hashlib.sha256()
    signature = lambda value: (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns)
    with path.open("rb") as stream:
        if signature(os.fstat(stream.fileno())) != signature(before):
            raise ValueError("opened profile input differs from inventory")
        consumed = 0
        while True:
            block = stream.read(min(1024 ** 2, before.st_size - consumed + 1))
            if not block:
                break
            consumed += len(block)
            if consumed > before.st_size:
                raise ValueError("profile input grew during bounded hashing")
            digest.update(block)
        if consumed != before.st_size or signature(os.fstat(stream.fileno())) != signature(before):
            raise ValueError("opened profile input changed during hashing")
    after = _physical(path, directory=False)
    if signature(before) != signature(after):
        raise ValueError("profile source changed during inventory")
    return {"source": str(path), "destination": destination, "bytes": before.st_size,
            "sha256": digest.hexdigest(), "identity": [before.st_dev, before.st_ino],
            "mtimeNs": before.st_mtime_ns}


def _make_plan(source, profile, engine, normal):
    members, runtime_directories = [], []
    for root in RUNTIME_ROOTS:
        tree = source / root
        _physical_directory(tree)
        files, directories = _inventory(tree)
        prefix = RUNTIME_PREFIXES[root]
        for directory in directories:
            if not (directory == prefix or directory.startswith(prefix + "/")
                    or prefix.startswith(directory + "/")
                    or (root == "shaders" and (directory == "common" or directory.startswith("common/")))):
                raise ValueError("runtime directory outside named BeamRT namespace refused")
        runtime_directories.append(MOD_DESTINATION + "/" + root)
        runtime_directories.extend(MOD_DESTINATION + "/" + root + "/" + d for d in directories)
        for relative, _ in files:
            if not relative.startswith(prefix + "/"):
                raise ValueError("runtime file outside named BeamRT namespace refused")
            if Path(relative).suffix.casefold() not in SUFFIXES[root]:
                raise ValueError("unexpected runtime extension refused: " + relative)
            members.append((tree / relative, MOD_DESTINATION + "/" + root + "/" + relative))
    controls = source / "native/startup/unattended"
    _physical_directory(controls)
    for name in CONTROLS:
        members.append((controls / name, "control/" + name))
    tools = Path(__file__).absolute().parent
    _physical_directory(tools)
    tool_members = [(tools / "isolated_profile.py", None), (tools / "protected_inputs.py", None)]
    # Enforce the aggregate read budget before hashing any payload.
    sizes = [_physical(path, directory=False).st_size for path, _ in members + tool_members]
    if len(sizes) > MAX_FILES or any(not 0 <= size <= MAX_FILE_BYTES for size in sizes) \
            or sum(sizes) > MAX_TOTAL_BYTES:
        raise ValueError("profile total input budget exceeded")
    records = [_record(path, destination) for path, destination in members]
    tool_records = [_record(path, destination) for path, destination in tool_members]
    if tool_records[1]["sha256"] != PROTECTED_SOURCE_SHA256:
        raise ValueError("original protected-input helper pin differs")
    all_records = records + tool_records
    if len(all_records) > MAX_FILES or sum(r["bytes"] for r in all_records) > MAX_TOTAL_BYTES:
        raise ValueError("profile total input budget exceeded")
    identities = [tuple(r["identity"]) for r in all_records]
    if len(set(identities)) != len(identities):
        raise ValueError("duplicate physical source identity refused")
    directories = {"control", *EMPTY_DIRECTORIES, *runtime_directories}
    for directory in tuple(directories):
        directories.update(p.as_posix() for p in Path(directory).parents if str(p) != ".")
    for directory in directories:
        _path(profile / directory)
    for record in records:
        _path(profile / record["destination"])
    return {"schema": SCHEMA, "sourceModRoot": str(source), "normalUserRoot": str(normal),
            "engineRoot": str(engine), "profileRoot": str(profile),
            "userBase": str(profile / "user"),
            "expectedUserFolder": str(profile / "user/current"),
            "candidateArgumentFragment": ["-userpath", str(profile / "user")],
            "files": sorted(records, key=lambda record: record["destination"]),
            "toolInputs": tool_records, "directories": sorted(directories)}


def build_plan(source_mod_root, profile_root, engine_root):
    """Read-only preparation review. Refuse an existing destination or aliased input."""
    roots = _roots(source_mod_root, profile_root, engine_root, fresh=True)
    return _make_plan(*roots)


def _json_bytes(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode("ascii")


def review_sha256(plan):
    return hashlib.sha256(_json_bytes(plan)).hexdigest()


def _validate_current(plan, *, fresh):
    if not isinstance(plan, dict) or plan.get("schema") != SCHEMA:
        raise ValueError("explicit isolated-profile plan required")
    try:
        roots = _roots(plan["sourceModRoot"], plan["profileRoot"], plan["engineRoot"], fresh=fresh)
    except KeyError as error:
        raise ValueError("profile root fields missing") from error
    if _make_plan(*roots) != plan:
        raise ValueError("reviewed profile plan or source namespace changed")


def _receipt(plan):
    return {"schema": SCHEMA, "reviewSha256": review_sha256(plan), "prepared": True,
            "profileRoot": plan["profileRoot"], "expectedUserFolder": plan["expectedUserFolder"],
            "copiedFiles": len(plan["files"]), "copiedBytes": sum(r["bytes"] for r in plan["files"]),
            "gameExecutionAvailable": False, "runtimeUserPathVerified": False,
            "runtimeDefaultsVerified": False, "vfsIsolationVerified": False,
            "namespaceSealed": False, "cloudIsolationVerified": False, "nativeGIEnabled": False}


def _verify_tree(plan, *, metadata):
    profile = _path(plan["profileRoot"])
    _physical_directory(profile)
    files, directories = _inventory(profile)
    expected = {r["destination"]: r for r in plan["files"]}
    if metadata:
        for leaf, value in ((PLAN_LEAF, plan), (RECEIPT_LEAF, _receipt(plan))):
            image = _json_bytes(value)
            expected[leaf] = {"bytes": len(image), "sha256": hashlib.sha256(image).hexdigest()}
    if {relative for relative, _ in files} != set(expected) or directories != plan["directories"]:
        raise ValueError("prepared profile namespace differs from the reviewed exact tree")
    source_ids = {tuple(r["identity"]) for r in plan["files"] + plan["toolInputs"]}
    for relative in expected:
        record = _record(profile / relative, relative)
        if tuple(record["identity"]) in source_ids:
            raise ValueError("destination aliases a protected source")
        if any(record[key] != expected[relative][key] for key in ("bytes", "sha256")):
            raise ValueError("prepared file bytes differ from reviewed held source")


def verify_prepared(plan):
    """Verify one physical checkpoint. No source execution or game-isolation claim."""
    # Validate all mapping fields against current source before trusting output paths.
    _validate_current(plan, fresh=False)
    _verify_tree(plan, metadata=True)
    return _receipt(plan)


def _write_new(path, image):
    with path.open("xb") as stream:
        if stream.write(image) != len(image):
            raise OSError("short exclusive profile write")
        stream.flush()
        os.fsync(stream.fileno())


def prepare(plan, expected_review_sha256, *, protector_factory, backend_factory):
    """Copy a reviewed plan once. On failure retain the partial tree, never retry.

    Factories must come from explicitly verified source. They provide file-only
    Win32 handles; no native host, claim, approval, subprocess or launch is used.
    """
    if not isinstance(expected_review_sha256, str) \
            or not re.fullmatch(r"[0-9a-f]{64}", expected_review_sha256) \
            or review_sha256(plan) != expected_review_sha256:
        raise ValueError("exact explicit preparation review SHA256 required")
    if not callable(protector_factory) or not callable(backend_factory):
        raise ValueError("explicit file-only protection dependencies required")
    _validate_current(plan, fresh=True)
    profile = _path(plan["profileRoot"])
    backend, handles, lease = backend_factory(), [], None
    try:
        # Hold destination ancestry before exclusive creation. Deny ordinary
        # directory rename, but do not pretend this seals child membership.
        for ancestor in _ancestors(profile.parent):
            if ancestor == Path(ancestor.anchor):
                backend.check_fixed_root(str(ancestor))
            handles.append(backend.open_directory(str(ancestor)))
        _validate_current(plan, fresh=True)
        profile.mkdir()
        handles.append(backend.open_directory(str(profile)))
        manifest = {r["source"]: r["sha256"] for r in plan["files"] + plan["toolInputs"]}
        lease = protector_factory(manifest, str(profile), _backend=backend,
                                  max_file_bytes=MAX_FILE_BYTES, max_total_bytes=MAX_TOTAL_BYTES)
        lease.open()
        _validate_current(plan, fresh=False)
        for relative in sorted(plan["directories"], key=lambda item: (item.count("/"), item)):
            directory = profile / relative
            directory.mkdir()
            handles.append(backend.open_directory(str(directory)))
        for record in plan["files"]:
            image = lease.read_bytes(record["source"], max_bytes=MAX_FILE_BYTES)
            if len(image) != record["bytes"] or hashlib.sha256(image).hexdigest() != record["sha256"]:
                raise ValueError("held source bytes differ from profile review")
            _write_new(profile / record["destination"], image)
        _validate_current(plan, fresh=False)
        _verify_tree(plan, metadata=False)
        _write_new(profile / PLAN_LEAF, _json_bytes(plan))
        _write_new(profile / RECEIPT_LEAF, _json_bytes(_receipt(plan)))
        _verify_tree(plan, metadata=True)
        return _receipt(plan)
    finally:
        active_error = sys.exc_info()[0] is not None
        cleanup_errors = []
        if lease is not None:
            try:
                lease.close()
            except BaseException as error:
                cleanup_errors.append(error)
        while handles:
            try:
                backend.close(handles.pop())
            except BaseException as error:
                cleanup_errors.append(error)
        if cleanup_errors and not active_error:
            raise OSError("profile protection cleanup failed; attempt retained") from cleanup_errors[0]
