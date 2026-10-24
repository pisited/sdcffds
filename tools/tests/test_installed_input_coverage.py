"""Inventory regressions only: no game, process or persistent setting changes."""
import copy
import hashlib
import importlib.util
import os
from pathlib import Path
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "native/startup/unattended/installed_input_coverage.py"
loader = importlib.util.spec_from_file_location("installed_coverage_test", SOURCE)
module = importlib.util.module_from_spec(loader)
loader.loader.exec_module(module)
DIGEST = "1" * 64

def spec():
    leaves = {"host": "beamrt_startup_host.exe", "dll": "beamrt_startup_bootstrap.dll",
              "decoder": "receipt_decoder.exe", "vertex": "target.vs.cso", "pixel": "target.ps.cso"}
    artifacts = {role: {"path": "C:\\native\\" + leaf, "sha256": DIGEST} for role, leaf in leaves.items()}
    return module.build_spec(r"C:\user\mods\unpacked\beamrt", r"E:\game", r"C:\user", artifacts)

def fake_group(group, *, hash_protected=True, hash_context=True):
    hashed = hash_context and group["category"] == "mutable-context" or hash_protected and group["category"] == "protected"
    records = [{"path": group["path"], "kind": group["kind"], "size": 5 if group["kind"] == "file" else 0,
                "mtime_ns": 1, "sha256": DIGEST if hashed and group["kind"] == "file" else None}]
    if group["kind"] == "directory":
        records.append({"path": group["path"] + r"\input.dat", "kind": "file", "size": 5,
                        "mtime_ns": 1, "sha256": DIGEST if hashed else None})
        for path in module._critical_members(spec()):
            if path.casefold().startswith(group["path"].casefold() + "\\") and group["category"] == "protected":
                records.append({"path": path, "kind": "file", "size": 5,
                                "mtime_ns": 1, "sha256": DIGEST if hashed else None})
    return {**group, "records": records}

def snapshot():
    with mock.patch.object(module, "_scan_group", side_effect=fake_group), \
            mock.patch.object(module, "_hash_file", return_value=DIGEST), \
            mock.patch.object(module, "_information", return_value=types.SimpleNamespace(st_size=5, st_mtime_ns=1)):
        return module.collect(spec())

def resign(value):
    value["coverageSHA256"] = hashlib.sha256(module._canonical(
        {key: item for key, item in value.items() if key != "coverageSHA256"})).hexdigest()

class SchemaTests(unittest.TestCase):
    def test_spec_is_pure_and_fixed_scope(self):
        with mock.patch.object(Path, "open", side_effect=AssertionError("must not read")):
            value = spec()
        self.assertEqual(value["scope"], module.SCOPE)
        self.assertEqual(set(value["artifacts"]), module.ARTIFACT_ROLES)

    def test_unsafe_paths_refuse(self):
        for path in ("relative", "C:\\", r"\\server\share", r"C:\one\..\two", r"C:\one:stream",
                     r"C:\CON.txt", "C:\\trailing ", "C:\\a\x00b", "C:\\a\\\\b"):
            with self.subTest(path=path), self.assertRaises((ValueError, UnicodeError)):
                module.canonical_path(path)

    def test_root_join_and_overlap_refuse(self):
        value = spec()
        for beamrt, engine in ((r"C:\other", r"E:\game"), (value["roots"]["beamrt"], r"C:\user\game")):
            with self.assertRaises(ValueError):
                module.build_spec(beamrt, engine, r"C:\user", value["artifacts"])

    def test_exact_schema_hashes_and_leaves(self):
        for change in (lambda v: v.update(extra=1), lambda v: v["artifacts"]["host"].update(sha256="X" * 64),
                       lambda v: v["artifacts"]["host"].update(path=r"C:\native\wrong.exe")):
            value = spec()
            change(value)
            with self.assertRaises(ValueError):
                module._validate_spec(value)

    def test_snapshot_validation_and_copy_manifest(self):
        value = snapshot()
        self.assertTrue(module.validate_snapshot(value))
        manifest = module.protection_manifest(value)
        manifest.clear()
        self.assertGreater(len(module.protection_manifest(value)), 1)

    def test_mutable_and_opaque_context_never_enter_held_manifest(self):
        value = snapshot()
        held = module.protection_manifest(value)
        for group in value["groups"]:
            if group["category"] != "protected":
                self.assertFalse(any(record["path"] in held for record in group["records"]))
        for field in ("gameExecutionAvailable", "namespaceSealed", "fullEnvironmentProtected", "mutableContextHeld"):
            self.assertIs(module.report(value)[field], False)

    def test_missing_group_refuses_even_with_new_digest(self):
        value = snapshot()
        value["groups"].pop()
        resign(value)
        with self.assertRaises(ValueError):
            module.validate_snapshot(value)

    def test_escaped_duplicate_wrong_type_and_wrong_root_records_refuse(self):
        for change in (lambda v: v["groups"][0]["records"][1].update(path=r"C:\escape\input"),
                       lambda v: v["groups"][0]["records"].append(copy.deepcopy(v["groups"][0]["records"][0])),
                       lambda v: v["groups"][0]["records"][1].update(size=True),
                       lambda v: v["groups"][0]["records"][0].update(kind="file", sha256=DIGEST)):
            value = snapshot()
            change(value)
            resign(value)
            with self.assertRaises(ValueError):
                module.validate_snapshot(value)

    def test_tampered_native_pin_refuses_even_with_new_snapshot_digest(self):
        value = snapshot()
        next(g for g in value["groups"] if g["name"] == "native-host")["records"][0]["sha256"] = "2" * 64
        resign(value)
        with self.assertRaisesRegex(ValueError, "reviewed pin"):
            module.validate_snapshot(value)

    def test_snapshot_digest_mutation_refuses(self):
        value = snapshot()
        value["coverageSHA256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "digest"):
            module.validate_snapshot(value)

    def test_missing_critical_control_member_refuses_initial_snapshot(self):
        value = snapshot()
        group = next(group for group in value["groups"] if group["name"] == "engine-lua")
        group["records"] = [record for record in group["records"] if not record["path"].endswith("parseArgs.lua")]
        resign(value)
        with self.assertRaisesRegex(ValueError, "entry-control"):
            module.validate_snapshot(value)

    def test_integer_policy_flags_are_not_exact_boolean_schema(self):
        value = snapshot()
        value["groups"][0]["recursive"] = 1
        resign(value)
        with self.assertRaisesRegex(ValueError, "policy"):
            module.validate_snapshot(value)

    def test_global_input_budgets_stay_bounded(self):
        value = snapshot()
        value["groups"][0]["records"][1]["size"] = module.MAX_FILE_BYTES + 1
        resign(value)
        with self.assertRaisesRegex(ValueError, "per-file"):
            module.validate_snapshot(value)
        value = snapshot()
        for group in value["groups"][:3]:
            group["records"][1]["size"] = module.MAX_FILE_BYTES
        resign(value)
        with self.assertRaisesRegex(ValueError, "scope exceeded"):
            module.validate_snapshot(value)

    def test_checkpoint_does_not_rehash_held_protected_files(self):
        value = snapshot()
        with mock.patch.object(module, "_scan_group", side_effect=fake_group) as scanner:
            self.assertTrue(module.checkpoint(value))
        self.assertTrue(all(call.kwargs == {"hash_protected": False} for call in scanner.call_args_list))

    def test_changed_missing_or_added_membership_refuses(self):
        for mutation in (lambda rows: rows.pop(), lambda rows: rows[0].update(mtime_ns=2),
                         lambda rows: rows.append({**rows[-1], "path": rows[-1]["path"] + ".new"})):
            value = snapshot()
            def changed(group, *, hash_protected=True):
                result = fake_group(group, hash_protected=hash_protected)
                if group["name"] == value["groups"][0]["name"]:
                    mutation(result["records"])
                return result
            with mock.patch.object(module, "_scan_group", side_effect=changed), self.assertRaisesRegex(ValueError, "drift"):
                module.checkpoint(value)

    def test_no_process_or_claim_api(self):
        source = SOURCE.read_text("utf-8")
        for forbidden in ("import subprocess", "Popen(", "CreateProcess", "TerminateProcess", "claim_attempt(", "--run-tests"):
            self.assertNotIn(forbidden, source)

    def test_collect_rejects_oversize_before_hashing_any_file(self):
        def oversized(group, **options):
            value = fake_group(group, **options)
            if group["name"] == "engine-lua":
                value["records"][1]["size"] = module.MAX_TOTAL_BYTES + 1
            return value
        with mock.patch.object(module, "_scan_group", side_effect=oversized), \
                mock.patch.object(module, "_hash_file") as hashing, self.assertRaisesRegex(ValueError, "before file reads"):
            module.collect(spec())
        hashing.assert_not_called()

class PhysicalScannerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="beamrt-inventory-")
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_walk_includes_gitignored_generated_assets_and_empty_dirs(self):
        (self.root / ".gitignore").write_text("generated/\n", encoding="ascii")
        (self.root / "generated").mkdir()
        (self.root / "generated/hook.hlsl").write_bytes(b"shader")
        (self.root / "empty").mkdir()
        rows = module._scan_tree(self.root)
        self.assertTrue(any(row["path"].endswith("hook.hlsl") and row["sha256"] == hashlib.sha256(b"shader").hexdigest() for row in rows))
        self.assertTrue(any(row["path"].endswith("empty") and row["kind"] == "directory" for row in rows))

    def test_control_exclusions_do_not_skip_code_in_directory_named_like_bytecode(self):
        for directory in (".git", ".beamrt-validation", "__pycache__", "scripts.pyc"):
            (self.root / directory).mkdir()
            (self.root / directory / "modScript.lua").write_bytes(b"code")
        (self.root / "cache.pyc").write_bytes(b"cached")
        rows = module._scan_tree(self.root, exclude_bytecode=True, exclude_controls=True)
        names = [str(Path(row["path"]).relative_to(self.root)).split(os.sep) for row in rows]
        self.assertTrue(any("scripts.pyc" in name for name in names))
        for excluded in (".git", ".beamrt-validation", "__pycache__", "cache.pyc"):
            self.assertFalse(any(excluded in name for name in names))

    def test_shallow_opaque_scan_does_not_read_archives_or_descend(self):
        (self.root / "mod.zip").write_bytes(b"archive")
        (self.root / "provider").mkdir()
        (self.root / "provider/unknown.lua").write_bytes(b"code")
        with mock.patch.object(module, "_hash_file", side_effect=AssertionError("must not read opaque bytes")):
            rows = module._scan_tree(self.root, recursive=False, with_hash=False)
        self.assertEqual(len(rows), 3)
        self.assertTrue(all(row["sha256"] is None for row in rows))

    def test_optional_absence_and_later_creation_are_distinct(self):
        missing = self.root / "absent/child"
        self.assertEqual(module._scan_tree(missing, required=False)[0]["kind"], "absent")
        missing.mkdir(parents=True)
        self.assertEqual(module._scan_tree(missing, required=False)[0]["kind"], "directory")
        with self.assertRaises(FileNotFoundError):
            module._scan_tree(self.root / "required")

    def test_symlink_root_and_parent_are_refused(self):
        target = self.root / "real"
        target.mkdir()
        (target / "input").write_bytes(b"data")
        link = self.root / "link"
        try:
            link.symlink_to(target, target_is_directory=True)
        except OSError:
            self.skipTest("creating symlink requires unavailable privilege")
        for path in (link, link / "input"):
            with self.assertRaisesRegex(ValueError, "reparse"):
                module._scan_tree(path)

    def test_file_mutation_during_read_refuses(self):
        path = self.root / "input"
        path.write_bytes(b"initial")
        info = path.stat()
        path.write_bytes(b"changed size")
        with self.assertRaisesRegex(ValueError, "changed"):
            module._hash_file(path, info)

if __name__ == "__main__":
    unittest.main()
