"""Disposable profile-staging contracts; never launch a game or a process."""
from contextlib import ExitStack
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
DIRECTORY = ROOT / "native/startup/unattended"
SOURCE = DIRECTORY / "isolated_profile.py"
CONTROL_LEAVES = ("early_shim.lua", "bootstrap.lua", "engine_adapter.lua", "controller.lua")
TREES = ("art", "lua", "scripts", "shaders")
PROFILE_LEAF = "beamrt-profile-0123456789abcdef"


def load_source(name):
    specification = importlib.util.spec_from_file_location(
        "beamrt_isolated_profile_contract_" + name, DIRECTORY / (name + ".py"))
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class ProbeBackend:
    """Portable ownership probe, not a simulation of Win32 sharing security."""
    def __init__(self):
        self.next_handle = 0
        self.handles, self.closed, self.fixed = {}, [], []

    def check_fixed_root(self, root):
        self.fixed.append(root)

    def open_directory(self, path):
        self.next_handle += 1
        self.handles[self.next_handle] = str(path)
        return self.next_handle

    def close(self, handle):
        if handle in self.closed:
            raise AssertionError("numeric handle closed twice")
        self.closed.append(handle)


class ProbeProtector:
    def __init__(self, manifest, run_directory, *, _backend, max_file_bytes, max_total_bytes):
        self.manifest = dict(manifest)
        self.run_directory = Path(run_directory)
        self.backend = _backend
        self.max_file_bytes, self.max_total_bytes = max_file_bytes, max_total_bytes
        self.closed, self.opened = False, False
        self.reads = []

    @property
    def digests(self):
        if not self.opened or self.closed:
            raise RuntimeError("fixture source lease is not open")
        return dict(self.manifest)

    def open(self):
        total = 0
        for name, expected in self.manifest.items():
            image = Path(name).read_bytes()
            if len(image) > self.max_file_bytes:
                raise ValueError("fixture per-file budget")
            total += len(image)
            if hashlib.sha256(image).hexdigest() != expected:
                raise ValueError("fixture held SHA256 mismatch")
        if total > self.max_total_bytes or len(self.manifest) > 512:
            raise ValueError("fixture total budget")
        self.opened = True
        return self

    def read_bytes(self, path, *, max_bytes):
        if not self.opened or self.closed:
            raise RuntimeError("fixture source lease is not open")
        path = str(path)
        if path not in self.manifest:
            raise ValueError("unheld fixture read")
        image = Path(path).read_bytes()
        if len(image) > max_bytes or hashlib.sha256(image).hexdigest() != self.manifest[path]:
            raise ValueError("fixture held read differs")
        self.reads.append(path)
        return image

    def close(self):
        self.closed = True

    def __enter__(self):
        return self.open()

    def __exit__(self, *_exception):
        self.close()


class ProfileFixture(unittest.TestCase):
    def setUp(self):
        self.module = load_source("isolated_profile")
        self.temporary = tempfile.TemporaryDirectory(prefix="beamrt-profile-contract-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.normal = self.directory / "normal/current"
        self.mod = self.normal / "mods/unpacked/beamrt"
        self.engine = self.directory / "engine"
        self.engine.mkdir()
        self.profile = self.directory / PROFILE_LEAF
        self.expected = {
            "art/beamrt/texture.dds": b"DDS fixture texture\n",
            "art/beamrt/icon.png": b"PNG fixture image\n",
            "lua/ge/extensions/beamrt/main.lua": b"return { start = function() end }\n",
            "scripts/beamrt/modScript.lua": b"-- disposable BeamRT mod loader\n",
            "shaders/beamrt/reflection.hlsl": b"float4 main() : SV_Target { return 0; }\n",
            "shaders/beamrt/materials.json": b'{"fixture":true}\n',
        }
        for relative, image in self.expected.items():
            path = self.mod / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(image)
        (self.mod / "art/beamrt/empty").mkdir()
        controls = self.mod / "native/startup/unattended"
        controls.mkdir(parents=True)
        for leaf in CONTROL_LEAVES:
            (controls / leaf).write_bytes(("-- fixture control " + leaf + "\n").encode("ascii"))
        (self.normal / "settings").mkdir()
        (self.normal / "settings/settings.json").write_bytes(b'{"normalUserSetting":17}\n')
        (self.normal / "mods/db.json").write_bytes(b'{"otherModsEnabled":true}\n')
        (self.normal / "temp/shaders").mkdir(parents=True)
        (self.normal / "temp/shaders/cached.bin").write_bytes(b"normal shader cache")
        self.backend = ProbeBackend()
        self.protectors = []

    def plan(self):
        return self.module.build_plan(self.mod, self.profile, self.engine)

    def factory(self, *arguments, **options):
        protector = ProbeProtector(*arguments, **options)
        self.protectors.append(protector)
        return protector

    def prepare(self, plan=None, **options):
        plan = self.plan() if plan is None else plan
        options.setdefault("protector_factory", self.factory)
        options.setdefault("backend_factory", lambda: self.backend)
        return self.module.prepare(plan, self.module.review_sha256(plan), **options)

    def assert_released(self):
        self.assertTrue(all(item.closed for item in self.protectors))
        self.assertEqual(set(self.backend.closed), set(self.backend.handles))
        self.assertEqual(len(self.backend.closed), len(self.backend.handles))

    def assert_normal_unchanged(self):
        self.assertEqual((self.normal / "settings/settings.json").read_bytes(), b'{"normalUserSetting":17}\n')
        self.assertEqual((self.normal / "mods/db.json").read_bytes(), b'{"otherModsEnabled":true}\n')
        self.assertEqual((self.normal / "temp/shaders/cached.bin").read_bytes(), b"normal shader cache")
        for relative, image in self.expected.items():
            self.assertEqual((self.mod / relative).read_bytes(), image)


class PlanningContracts(ProfileFixture):
    def test_import_is_inert_without_process_or_file_operations(self):
        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(subprocess, "Popen", side_effect=AssertionError("process created")))
            stack.enter_context(mock.patch.object(os, "system", side_effect=AssertionError("shell invoked")))
            stack.enter_context(mock.patch.object(Path, "open", side_effect=AssertionError("path opened")))
            stack.enter_context(mock.patch.object(Path, "mkdir", side_effect=AssertionError("directory created")))
            self.assertTrue(callable(load_source("isolated_profile").build_plan))

    def test_build_plan_reads_without_creating_profile_or_mutating_inputs(self):
        plan = self.plan()
        self.assertIsInstance(plan, dict)
        self.assertFalse(self.profile.exists())
        self.assert_normal_unchanged()

    def test_review_digest_is_deterministic_lowercase_sha256(self):
        plan = self.plan()
        digest = self.module.review_sha256(plan)
        self.assertRegex(digest, r"^[0-9a-f]{64}$")
        self.assertEqual(digest, self.module.review_sha256(copy.deepcopy(plan)))
        self.assertEqual(plan, self.plan())

    def test_relative_source_profile_or_engine_refuses(self):
        arguments = ((Path("mods/unpacked/beamrt"), self.profile, self.engine),
                     (self.mod, Path(PROFILE_LEAF), self.engine),
                     (self.mod, self.profile, Path("engine")))
        for values in arguments:
            with self.subTest(values=values), self.assertRaises(ValueError):
                self.module.build_plan(*values)
        self.assertFalse(self.profile.exists())

    def test_profile_leaf_and_existing_parent_are_required(self):
        for path in (self.directory / "ordinary-profile", self.directory / "beamrt-profile-ABCDEF012345",
                     self.directory / "beamrt-profile-123", self.directory / "missing" / PROFILE_LEAF):
            with self.subTest(path=path), self.assertRaises((ValueError, FileNotFoundError)):
                self.module.build_plan(self.mod, path, self.engine)

    def test_normal_user_engine_and_source_overlap_refuse(self):
        for path in (self.mod / PROFILE_LEAF, self.normal / PROFILE_LEAF, self.engine / PROFILE_LEAF):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.module.build_plan(self.mod, path, self.engine)
        inside_user = self.normal / "engine"
        inside_user.mkdir()
        with self.assertRaises(ValueError):
            self.module.build_plan(self.mod, self.profile, inside_user)

    def test_wrong_installed_mod_join_refuses(self):
        wrong = self.directory / "not-installed-beamrt"
        wrong.mkdir()
        with self.assertRaises(ValueError):
            self.module.build_plan(wrong, self.profile, self.engine)

    def test_ambiguous_source_spelling_and_device_components_refuse(self):
        # Pass strings: Path itself normalizes some ambiguous dot spellings.
        for raw in (str(self.mod.parent) + os.sep + "." + os.sep + "beamrt",
                    str(self.mod.parent) + os.sep + ".." + os.sep + "unpacked" + os.sep + "beamrt",
                    str(self.mod) + os.sep, str(self.mod) + ":stream",
                    str(self.mod.parent) + os.sep + "CON.txt"):
            with self.subTest(path=raw), self.assertRaises((ValueError, FileNotFoundError)):
                self.module.build_plan(raw, self.profile, self.engine)

    def test_file_directory_and_cumulative_input_budgets_are_bounded(self):
        for name, value in (("MAX_FILES", 1), ("MAX_DIRECTORIES", 1),
                            ("MAX_FILE_BYTES", 1), ("MAX_TOTAL_BYTES", 1)):
            with self.subTest(budget=name), mock.patch.object(self.module, name, value):
                with self.assertRaisesRegex(ValueError, "budget"):
                    self.plan()
        self.assertFalse(self.profile.exists())

    def test_missing_required_runtime_tree_or_control_refuses(self):
        missing = self.mod / "art"
        renamed = self.mod / "art-held-back"
        missing.rename(renamed)
        try:
            with self.assertRaises((ValueError, FileNotFoundError)):
                self.plan()
        finally:
            renamed.rename(missing)
        control = self.mod / "native/startup/unattended/early_shim.lua"
        control.unlink()
        with self.assertRaises((ValueError, FileNotFoundError)):
            self.plan()

    def test_unexpected_runtime_binary_refuses_before_profile_creation(self):
        (self.mod / "shaders/beamrt/unreviewed.dll").write_bytes(b"not a shader")
        with self.assertRaises(ValueError):
            self.plan()
        self.assertFalse(self.profile.exists())

    def test_nested_runtime_binary_refuses_instead_of_being_silently_skipped(self):
        path = self.mod / "art/beamrt/nested/hidden.exe"
        path.parent.mkdir()
        path.write_bytes(b"not runtime data")
        with self.assertRaises(ValueError):
            self.plan()

    def test_foreign_autoload_and_shader_namespace_files_are_not_reviewable_as_beamrt(self):
        for relative in ("lua/ge/main.lua", "scripts/other/modScript.lua", "art/foreign/texture.png",
                         "shaders/common/foreign.hlsl"):
            path = self.mod / relative
            created_directories = [parent for parent in path.parents if not parent.exists()]
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"foreign runtime input must not enter isolated profile")
            with self.subTest(relative=relative), self.assertRaisesRegex(ValueError, "namespace"):
                self.plan()
            path.unlink()
            for directory in created_directories:
                directory.rmdir()
        self.assertFalse(self.profile.exists())

    def test_aggregate_budget_refuses_before_opening_any_payload(self):
        with mock.patch.object(self.module, "MAX_TOTAL_BYTES", 1), \
                mock.patch.object(Path, "open", side_effect=AssertionError("payload opened before budget refusal")):
            with self.assertRaisesRegex(ValueError, "budget"):
                self.plan()
        self.assertFalse(self.profile.exists())

    def test_growing_source_hash_read_is_bounded_and_refused(self):
        source = self.mod / "art/beamrt/texture.dds"
        original_open = Path.open
        reads = []
        class GrowingReader:
            def __init__(self, stream):
                self.stream = stream
                self.appended = False
            def fileno(self):
                return self.stream.fileno()
            def read(self, capacity):
                reads.append(capacity)
                if not self.appended:
                    self.appended = True
                    with original_open(source, "ab") as writer:
                        writer.write(b"!")
                return self.stream.read(capacity)
            def __enter__(self):
                return self
            def __exit__(self, *_exception):
                self.stream.close()
        def growing_open(path, *arguments, **options):
            stream = original_open(path, *arguments, **options)
            if path == source and arguments and arguments[0] == "rb":
                return GrowingReader(stream)
            return stream
        with mock.patch.object(Path, "open", growing_open):
            with self.assertRaisesRegex(ValueError, "grew|changed"):
                self.plan()
        self.assertTrue(reads)
        self.assertTrue(all(type(capacity) is int and 0 < capacity <= 1024 ** 2 for capacity in reads))
        self.assertFalse(self.profile.exists())

    def test_hardlink_aliases_in_runtime_source_refuse(self):
        os.link(self.mod / "art/beamrt/texture.dds", self.mod / "art/beamrt/alias.dds")
        with self.assertRaises(ValueError):
            self.plan()
        self.assertFalse(self.profile.exists())

    def test_symlink_source_or_profile_parent_refuses(self):
        alias = self.directory / "alias"
        try:
            alias.symlink_to(self.mod, target_is_directory=True)
        except OSError:
            self.skipTest("creating a directory symlink requires unavailable privilege")
        with self.assertRaises(ValueError):
            self.module.build_plan(alias, self.profile, self.engine)
        self.profile = alias / PROFILE_LEAF
        with self.assertRaises(ValueError):
            self.plan()

    def test_runtime_file_symlink_refuses(self):
        alias = self.mod / "art/beamrt/alias.dds"
        try:
            alias.symlink_to(self.mod / "art/beamrt/texture.dds")
        except OSError:
            self.skipTest("creating a file symlink requires unavailable privilege")
        with self.assertRaises(ValueError):
            self.plan()

    @unittest.skipIf(os.name == "nt", "case aliases cannot coexist on the normal Windows test volume")
    def test_case_aliased_source_members_refuse(self):
        (self.mod / "shaders/beamrt/REFLECTION.HLSL").write_bytes(b"case alias")
        with self.assertRaises(ValueError):
            self.plan()

    def test_unrelated_mod_control_and_normal_user_context_are_not_copied(self):
        for relative in (".git/config", ".beamrt-validation/stale.txt", "native/unreviewed.dll",
                         "tools/test.py", "README.md"):
            path = self.mod / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"not selected runtime content")
        self.plan()
        self.assertFalse(self.profile.exists())


class PreparationContracts(ProfileFixture):
    def test_prepare_copies_exact_bytes_preserves_empty_dirs_and_writes_joined_receipts(self):
        plan = self.plan()
        receipt = self.prepare(plan)
        self.assertIs(receipt["prepared"], True)
        for key in ("gameExecutionAvailable", "runtimeUserPathVerified", "runtimeDefaultsVerified",
                    "vfsIsolationVerified", "namespaceSealed", "cloudIsolationVerified", "nativeGIEnabled"):
            self.assertIs(receipt[key], False)
        copied = self.profile / "user/current/mods/unpacked/beamrt"
        for relative, image in self.expected.items():
            self.assertEqual((copied / relative).read_bytes(), image)
            self.assertFalse(os.path.samefile(self.mod / relative, copied / relative))
        self.assertTrue((copied / "art/beamrt/empty").is_dir())
        self.assertEqual({path.name for path in copied.iterdir()}, set(TREES))
        self.assertEqual(list((self.profile / "user/current/settings").iterdir()), [])
        self.assertEqual(list((self.profile / "user/current/temp/shaders").iterdir()), [])
        self.assertFalse((self.profile / "user/current/mods/db.json").exists())
        for leaf in CONTROL_LEAVES:
            self.assertEqual((self.profile / "control" / leaf).read_bytes(),
                             (self.mod / "native/startup/unattended" / leaf).read_bytes())
        self.assertEqual(json.loads((self.profile / "profile-plan.json").read_bytes()), plan)
        self.assertEqual(json.loads((self.profile / "profile-receipt.json").read_bytes()), receipt)
        self.assertEqual(self.module.verify_prepared(plan), receipt)
        self.assert_normal_unchanged()
        self.assert_released()

    def test_explicit_review_pin_and_factories_are_required(self):
        plan = self.plan()
        with self.assertRaises(TypeError):
            self.module.prepare(plan, self.module.review_sha256(plan))
        for digest in ("0" * 64, "A" * 64, True, None, ""):
            with self.subTest(digest=digest), self.assertRaises((ValueError, TypeError)):
                self.module.prepare(plan, digest, protector_factory=self.factory,
                                    backend_factory=lambda: self.backend)
        self.assertFalse(self.profile.exists())

    def test_existing_empty_profile_is_not_reused_or_deleted(self):
        plan = self.plan()
        self.profile.mkdir()
        with self.assertRaises((FileExistsError, ValueError)):
            self.prepare(plan)
        self.assertTrue(self.profile.is_dir())
        self.assertEqual(list(self.profile.iterdir()), [])
        self.assert_normal_unchanged()

    def test_existing_profile_content_is_not_overwritten(self):
        plan = self.plan()
        self.profile.mkdir()
        marker = self.profile / "valuable.txt"
        marker.write_bytes(b"keep existing user-owned output")
        with self.assertRaises((FileExistsError, ValueError)):
            self.prepare(plan)
        self.assertEqual(marker.read_bytes(), b"keep existing user-owned output")

    def test_successful_profile_cannot_be_prepared_twice(self):
        plan = self.plan()
        before = self.prepare(plan)
        with self.assertRaises((FileExistsError, ValueError)):
            self.prepare(plan)
        self.assertEqual(self.module.verify_prepared(plan), before)

    def test_changed_or_missing_planned_source_refuses_and_releases(self):
        for mutation in (lambda path: path.write_bytes(b"changed after review"), lambda path: path.unlink()):
            plan = self.plan()
            source = self.mod / "shaders/beamrt/reflection.hlsl"
            with self.subTest(mutation=mutation):
                mutation(source)
                with self.assertRaises((ValueError, OSError)):
                    self.prepare(plan)
                self.assertFalse((self.profile / "profile-receipt.json").exists())
                self.assert_released()
            source.write_bytes(self.expected["shaders/beamrt/reflection.hlsl"])
            if self.profile.exists():
                # Failed attempts are retained and must not be silently reused.
                self.profile = self.directory / "beamrt-profile-1123456789abcdef"

    def test_added_source_member_after_review_refuses(self):
        plan = self.plan()
        (self.mod / "shaders/beamrt/new.hlsl").write_bytes(b"new source after review")
        with self.assertRaises(ValueError):
            self.prepare(plan)
        self.assertFalse((self.profile / "profile-receipt.json").exists())
        self.assert_released()

    def test_extra_plan_field_is_not_accepted_with_the_original_review(self):
        plan = self.plan()
        changed = copy.deepcopy(plan)
        changed["unexpectedField"] = True
        with self.assertRaises(ValueError):
            self.module.prepare(changed, self.module.review_sha256(plan),
                                protector_factory=self.factory, backend_factory=lambda: self.backend)
        self.assertFalse(self.profile.exists())

    def test_resigned_plan_mapping_and_tool_pin_mutations_refuse_before_copy(self):
        plan = self.plan()
        mutations = (
            lambda value: value["files"][0].update(destination="../escape.lua"),
            lambda value: value["files"][0].update(source=str(self.normal / "settings/settings.json")),
            lambda value: value["toolInputs"][0].update(sha256="0" * 64),
            lambda value: value["directories"].append("../escape"),
            lambda value: value.update(candidateArgumentFragment=["-userpath", str(self.normal)]),
            lambda value: value.update(extraField=True),
        )
        for mutation in mutations:
            changed = copy.deepcopy(plan)
            mutation(changed)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                self.module.prepare(changed, self.module.review_sha256(changed),
                                    protector_factory=self.factory, backend_factory=lambda: self.backend)
        self.assertFalse(self.profile.exists())
        self.assert_normal_unchanged()

    def test_protected_helper_pin_must_match_the_reviewed_original(self):
        with mock.patch.object(self.module, "PROTECTED_SOURCE_SHA256", "0" * 64):
            with self.assertRaisesRegex(ValueError, "helper pin"):
                self.plan()
        self.assertFalse(self.profile.exists())

    def test_held_read_failure_keeps_partial_profile_without_success_receipt(self):
        class FailingProtector(ProbeProtector):
            def read_bytes(self, path, *, max_bytes):
                raise OSError("injected held source read failure")
        def factory(*arguments, **options):
            protector = FailingProtector(*arguments, **options)
            self.protectors.append(protector)
            return protector
        with self.assertRaisesRegex(OSError, "held source read failure"):
            self.prepare(protector_factory=factory)
        self.assertTrue(self.profile.is_dir())
        self.assertFalse((self.profile / "profile-receipt.json").exists())
        self.assert_normal_unchanged()
        self.assert_released()

    def test_partial_lease_open_failure_still_closes_lease_and_destination_handles(self):
        class FailingProtector(ProbeProtector):
            def open(self):
                self.opened = True
                raise OSError("injected partial source lease failure")
        def factory(*arguments, **options):
            protector = FailingProtector(*arguments, **options)
            self.protectors.append(protector)
            return protector
        with self.assertRaisesRegex(OSError, "partial source lease failure"):
            self.prepare(protector_factory=factory)
        self.assert_released()
        self.assertFalse((self.profile / "profile-receipt.json").exists())

    def test_source_lease_close_failure_does_not_skip_destination_close_attempts(self):
        class FailingProtector(ProbeProtector):
            def close(self):
                super().close()
                raise OSError("injected source lease close failure")
        def factory(*arguments, **options):
            protector = FailingProtector(*arguments, **options)
            self.protectors.append(protector)
            return protector
        with self.assertRaises(OSError) as failure:
            self.prepare(protector_factory=factory)
        self.assertIn("source lease close failure", str(failure.exception.__cause__ or failure.exception))
        self.assert_released()
        self.assert_normal_unchanged()

    def test_one_destination_close_failure_does_not_skip_remaining_close_attempts(self):
        original = self.backend.close
        first = True
        def failing_close(handle):
            nonlocal first
            original(handle)
            if first:
                first = False
                raise OSError("injected destination close failure")
        self.backend.close = failing_close
        with self.assertRaises(OSError) as failure:
            self.prepare()
        self.assertIn("destination close failure", str(failure.exception.__cause__ or failure.exception))
        self.assert_released()
        self.assert_normal_unchanged()

    def test_partial_destination_directory_open_failure_closes_prior_handles(self):
        original = self.backend.open_directory
        def failing_open(path):
            if Path(path) == self.profile:
                raise OSError("injected destination directory-open failure")
            return original(path)
        self.backend.open_directory = failing_open
        with self.assertRaisesRegex(OSError, "directory-open failure"):
            self.prepare()
        self.assert_released()
        self.assertTrue(self.profile.exists())
        self.assertFalse((self.profile / "profile-receipt.json").exists())

    def test_fsync_failure_does_not_publish_success_or_remove_partial_evidence(self):
        with mock.patch.object(os, "fsync", side_effect=OSError("injected fsync failure")):
            with self.assertRaisesRegex(OSError, "fsync failure"):
                self.prepare()
        self.assertTrue(self.profile.is_dir())
        self.assertFalse((self.profile / "profile-receipt.json").exists())
        self.assert_normal_unchanged()
        self.assert_released()

    def test_partial_copy_write_failure_keeps_existing_normal_files_and_releases(self):
        original = Path.open
        destination = self.profile / "user/current/mods/unpacked/beamrt/lua/ge/extensions/beamrt/main.lua"
        def refuse_main(path, *arguments, **options):
            mode = arguments[0] if arguments else options.get("mode", "r")
            if path == destination and any(flag in mode for flag in "wax"):
                raise OSError("injected destination write failure")
            return original(path, *arguments, **options)
        with mock.patch.object(Path, "open", refuse_main):
            with self.assertRaisesRegex(OSError, "destination write failure"):
                self.prepare()
        self.assertTrue(self.profile.is_dir())
        self.assertFalse((self.profile / "profile-receipt.json").exists())
        self.assert_normal_unchanged()
        self.assert_released()

    def test_verify_refuses_missing_changed_or_additional_prepared_content(self):
        plan = self.plan()
        self.prepare(plan)
        copied = self.profile / "user/current/mods/unpacked/beamrt/shaders/beamrt/reflection.hlsl"
        original = copied.read_bytes()
        copied.write_bytes(b"changed prepared shader")
        with self.assertRaises(ValueError):
            self.module.verify_prepared(plan)
        copied.write_bytes(original)
        copied.unlink()
        with self.assertRaises((ValueError, FileNotFoundError)):
            self.module.verify_prepared(plan)
        copied.write_bytes(original)
        extra = self.profile / "user/current/mods/unpacked/other-mod"
        extra.mkdir()
        with self.assertRaises(ValueError):
            self.module.verify_prepared(plan)

    def test_verify_refuses_user_settings_or_shader_cache_materialization_before_launch(self):
        plan = self.plan()
        self.prepare(plan)
        settings = self.profile / "user/current/settings/settings.json"
        settings.write_bytes(b"not pristine")
        with self.assertRaises(ValueError):
            self.module.verify_prepared(plan)
        settings.unlink()
        cache = self.profile / "user/current/temp/shaders/generated.bin"
        cache.write_bytes(b"not pristine")
        with self.assertRaises(ValueError):
            self.module.verify_prepared(plan)

    def test_verify_refuses_plan_or_receipt_metadata_mutation(self):
        plan = self.plan()
        receipt = self.prepare(plan)
        path = self.profile / "profile-receipt.json"
        changed = dict(receipt, runtimeUserPathVerified=True)
        path.write_text(json.dumps(changed), encoding="utf-8")
        with self.assertRaises(ValueError):
            self.module.verify_prepared(plan)

    def test_verify_refuses_prepared_hardlink_alias(self):
        plan = self.plan()
        self.prepare(plan)
        path = self.profile / "user/current/mods/unpacked/beamrt/art/beamrt/texture.dds"
        path.unlink()
        os.link(self.mod / "art/beamrt/texture.dds", path)
        with self.assertRaises(ValueError):
            self.module.verify_prepared(plan)
        self.assert_normal_unchanged()

    def test_final_readback_failure_retains_attempt_but_cannot_be_reused(self):
        plan = self.plan()
        original = self.module._verify_tree
        def refuse_final(value, *, metadata):
            original(value, metadata=metadata)
            if metadata:
                raise OSError("injected final-readback failure")
        with mock.patch.object(self.module, "_verify_tree", refuse_final):
            with self.assertRaisesRegex(OSError, "final-readback failure"):
                self.prepare(plan)
        self.assertTrue(self.profile.is_dir())
        # A receipt's presence after a publication/readback failure is not the
        # prepare call's success. All bytes remain for diagnosis, never retry.
        with self.assertRaises((FileExistsError, ValueError)):
            self.prepare(plan)
        self.assert_normal_unchanged()
        self.assert_released()

    def test_all_runtime_reads_are_from_explicit_held_scope_with_bounded_limits(self):
        self.prepare()
        self.assertTrue(self.protectors)
        self.assertTrue(any(item.reads for item in self.protectors))
        for item in self.protectors:
            self.assertEqual(item.max_file_bytes, 32 * 1024 ** 2)
            self.assertEqual(item.max_total_bytes, 128 * 1024 ** 2)
            self.assertLessEqual(len(item.manifest), 512)
            self.assertTrue(all(path in item.manifest for path in item.reads))
        self.assert_released()

    def test_source_contains_no_launch_or_destructive_cleanup_entrypoints(self):
        source = SOURCE.read_text("utf-8")
        for forbidden in ("import subprocess", "Popen(", "CreateProcess", "OpenProcess",
                          "TerminateProcess", "os.system(", "os.startfile(", "shutil.rmtree(",
                          ".unlink(", "os.remove(", "os.rmdir("):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, source)

    def test_unicode_and_spaces_are_preserved_in_plain_byte_copies(self):
        path = self.mod / "art/beamrt/space and snow 雪.png"
        path.write_bytes(b"unicode fixture name")
        plan = self.plan()
        self.prepare(plan)
        copied = self.profile / "user/current/mods/unpacked/beamrt/art/beamrt" / path.name
        self.assertEqual(copied.read_bytes(), b"unicode fixture name")
        self.assertEqual(self.module.verify_prepared(plan)["prepared"], True)


@unittest.skipUnless(os.name == "nt", "real sharing/retained-directory guarantees require Windows")
class WindowsPreparationContracts(ProfileFixture):
    def setUp(self):
        super().setUp()
        self.helper = load_source("protected_inputs")

    def prepare_real(self, plan=None, *, factory=None):
        plan = self.plan() if plan is None else plan
        return self.module.prepare(plan, self.module.review_sha256(plan),
            protector_factory=factory or self.helper.ProtectedInputs,
            backend_factory=self.helper._Win32)

    def test_actual_win32_source_leases_copy_and_release_without_normal_setting_changes(self):
        plan = self.plan()
        receipt = self.prepare_real(plan)
        self.assertEqual(self.module.verify_prepared(plan), receipt)
        self.assert_normal_unchanged()
        path = self.mod / "shaders/beamrt/reflection.hlsl"
        path.write_bytes(b"released after actual profile staging")
        moved = self.directory / "moved-profile"
        self.profile.rename(moved)
        moved.rename(self.profile)

    def test_actual_source_write_delete_and_directory_rename_are_denied_during_copy(self):
        source = self.mod / "shaders/beamrt/reflection.hlsl"
        outer = self
        class CheckedProtector(self.helper.ProtectedInputs):
            def read_bytes(self, path, *, max_bytes):
                with outer.assertRaises(OSError):
                    source.write_bytes(b"must remain frozen")
                with outer.assertRaises(OSError):
                    source.unlink()
                with outer.assertRaises(OSError):
                    outer.mod.rename(outer.mod.with_name("renamed-beamrt"))
                with outer.assertRaises(OSError):
                    outer.profile.rename(outer.profile.with_name("moved-profile"))
                settings = outer.profile / "user/current/settings"
                with outer.assertRaises(OSError):
                    settings.rename(settings.with_name("moved-settings"))
                return super().read_bytes(path, max_bytes=max_bytes)
        plan = self.plan()
        self.prepare_real(plan, factory=CheckedProtector)
        source.write_bytes(b"released after retained-source check")

    def test_actual_failed_held_read_releases_source_and_profile_directories(self):
        class FailingProtector(self.helper.ProtectedInputs):
            def read_bytes(self, _path, *, max_bytes):
                raise OSError("actual fixture source read failure")
        with self.assertRaisesRegex(OSError, "source read failure"):
            self.prepare_real(factory=FailingProtector)
        (self.mod / "shaders/beamrt/reflection.hlsl").write_bytes(b"released after actual error")
        self.assertFalse((self.profile / "profile-receipt.json").exists())
        moved = self.directory / "failed-profile-released"
        self.profile.rename(moved)
        moved.rename(self.profile)

    def test_actual_junction_profile_parent_refuses_without_symlink_privilege(self):
        real_parent = self.directory / "actual-profile-parent"
        real_parent.mkdir()
        alias = self.directory / "junction-profile-parent"
        alias.mkdir()
        self.addCleanup(lambda: os.rmdir(alias) if alias.exists() else None)
        backend = self.helper._Win32()
        handle = backend._open(str(alias), 0x40000000, 7, 3, 0x02000000 | 0x00200000)
        ctypes, win = self.helper.ctypes, self.helper.wintypes
        control = backend.api.DeviceIoControl
        control.argtypes = [win.HANDLE, win.DWORD, ctypes.c_void_p, win.DWORD,
                            ctypes.c_void_p, win.DWORD, ctypes.POINTER(win.DWORD), ctypes.c_void_p]
        control.restype = win.BOOL
        substitute = ("\\??\\" + str(real_parent)).encode("utf-16-le")
        printed = str(real_parent).encode("utf-16-le")
        paths = substitute + b"\0\0" + printed + b"\0\0"
        data = struct.pack("<LHHHHHH", 0xA0000003, 8 + len(paths), 0,
                           0, len(substitute), len(substitute) + 2, len(printed)) + paths
        returned = win.DWORD()
        try:
            if not control(handle, 0x000900A4, data, len(data), None, 0,
                           ctypes.byref(returned), None):
                raise backend._error()
        finally:
            backend.close(handle)
        with self.assertRaisesRegex(ValueError, "reparse"):
            self.module.build_plan(self.mod, alias / PROFILE_LEAF, self.engine)
        self.assertEqual(list(real_parent.iterdir()), [])
        self.assert_normal_unchanged()


if __name__ == "__main__":
    unittest.main()
