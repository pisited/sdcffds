"""Physical input locks and one-shot claims; no process or game operations."""
from contextlib import ExitStack
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "native/startup/unattended/protected_inputs.py"
TOKEN = "0123456789abcdef0123456789abcdef"
DIGEST = "a" * 64


def load_helper():
    spec = importlib.util.spec_from_file_location("beamrt_protected_inputs_contract", SOURCE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FileBackend:
    def __init__(self, files=None):
        self.files = files or {r"C:\frozen\one.py": b"one", r"C:\frozen\two.exe": b"two"}
        self.handles, self.closed, self.events = {}, [], []
        self.positions, self.existing, self.created = {}, set(), []
        self.identities = {path: (1, 0, index + 1) for index, path in enumerate(self.files)}
        self.next_handle = 0

    def allocate(self, kind, path):
        self.next_handle += 1
        self.handles[self.next_handle] = (kind, path)
        self.positions[self.next_handle] = 0
        self.events.append((kind, path))
        return self.next_handle

    def check_fixed_root(self, root):
        self.events.append(("fixed", root))

    def open_directory(self, path):
        return self.allocate("directory", path)

    def open_input(self, path):
        if path not in self.files:
            raise FileNotFoundError(path)
        return self.allocate("input", path), self.identities[path]

    def size(self, handle):
        return len(self.files[self.handles[handle][1]])

    def position(self, handle):
        return self.positions[handle]

    def seek(self, handle, position):
        self.positions[handle] = position

    def chunks(self, handle, maximum):
        self.positions[handle] = 0
        data = self.files[self.handles[handle][1]]
        if len(data) > maximum:
            raise ValueError("mock read budget")
        self.positions[handle] = len(data)
        yield data

    def exists(self, path):
        self.events.append(("exists", path))
        return path in self.existing

    def create_claim(self, path, image):
        if path in self.existing:
            raise FileExistsError(path)
        self.existing.add(path)
        self.created.append((path, image))
        return self.allocate("claim", path)

    def close(self, handle):
        self.closed.append(handle)
        self.events.append(("close", self.handles[handle][1]))


class ProtectedInputContracts(unittest.TestCase):
    def setUp(self):
        self.helper = load_helper()
        self.backend = FileBackend()
        self.manifest = {path: hashlib.sha256(data).hexdigest()
                         for path, data in self.backend.files.items()}

    def scope(self, **options):
        options.setdefault("_backend", self.backend)
        return self.helper.ProtectedInputs(self.manifest, r"C:\evidence\run", **options)

    def test_import_is_inert_without_file_reads_win32_or_creation(self):
        with ExitStack() as stack:
            stack.enter_context(patch.object(Path, "open", side_effect=AssertionError("import read file")))
            stack.enter_context(patch.object(os, "open", side_effect=AssertionError("import created file")))
            if hasattr(self.helper.ctypes, "WinDLL"):
                stack.enter_context(patch.object(self.helper.ctypes, "WinDLL", side_effect=AssertionError("import used Win32")))
            self.assertTrue(callable(load_helper().ProtectedInputs))

    def test_pure_manifest_normalizes_slashes_and_drive_letter(self):
        result = self.helper.validate_manifest({"c:/frozen/a.py": DIGEST})
        self.assertEqual(result, ((r"C:\frozen\a.py", DIGEST),))

    def test_lexical_ambiguous_paths_are_rejected_without_backend_calls(self):
        paths = ("", "relative", r"C:relative", r"\rooted", r"\\server\share\file",
                 r"\\?\C:\file", r"\\.\C:\file", r"C:\folder\..\file", r"C:\folder\.\file",
                 "C:\\folder\\file.", "C:\\folder\\file ", "C:\\folder\\",
                 r"C:\folder\file:stream", r"C:\folder\NUL.txt", r"C:\folder\com1.exe",
                 r"C:\folder\LPT².log", r"C:\folder\CONIN$", r"C:\folder\a?b", "C:\\bad\x00name")
        for path in paths:
            with self.subTest(path=repr(path)), self.assertRaises((ValueError, TypeError)):
                self.helper.ProtectedInputs({path: DIGEST}, r"C:\evidence\run", _backend=self.backend)
        self.assertEqual(self.backend.events, [])

    def test_manifest_shape_hash_and_budget_refusals_are_pure(self):
        for manifest in ({}, [], None, "abc", ["pair"], [(r"C:\a",)],
                         {r"C:\a": "A" * 64}, {r"C:\a": "0" * 63},
                         {r"C:\a": False}):
            with self.subTest(manifest=manifest), self.assertRaises(ValueError):
                self.helper.validate_manifest(manifest)
        for key, value in (("max_file_bytes", 0), ("max_file_bytes", True),
                           ("max_file_bytes", 1024 ** 3 + 1), ("max_total_bytes", 2 * 1024 ** 3 + 1)):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                self.helper.validate_manifest(self.manifest, **{key: value})

    def test_duplicate_and_case_alias_entries_are_refused(self):
        for second in (r"C:\frozen\one.py", r"c:\FROZEN\ONE.PY", "C:/frozen/one.py"):
            with self.subTest(second=second), self.assertRaises(ValueError):
                self.helper.validate_manifest([(r"C:\frozen\one.py", DIGEST), (second, DIGEST)])

    def test_drive_root_is_not_a_scoped_run_directory(self):
        with self.assertRaises(ValueError):
            self.helper.ProtectedInputs(self.manifest, "C:\\", _backend=self.backend)
        self.assertEqual(self.backend.events, [])

    def test_manifest_count_is_bounded(self):
        with self.assertRaises(ValueError):
            self.helper.validate_manifest([(fr"C:\frozen\{index}.py", DIGEST) for index in range(513)])

    def test_scope_hashes_held_handles_and_retains_unique_ancestors(self):
        with self.scope() as protected:
            self.assertEqual(protected.digests, self.manifest)
            copied = protected.digests
            copied.clear()
            self.assertEqual(protected.digests, self.manifest)
            directories = [path for kind, path in self.backend.events if kind == "directory"]
            self.assertEqual(directories, ["C:\\", r"C:\evidence", r"C:\evidence\run", r"C:\frozen"])
            self.assertEqual(self.backend.closed, [])
            self.assertEqual(self.backend.created, [])
        self.assertEqual(self.backend.closed, sorted(self.backend.handles, reverse=True))
        with self.assertRaises(RuntimeError):
            protected.open()

    def test_open_then_context_manager_is_supported_but_nesting_refused(self):
        protected = self.scope().open()
        with protected:
            with self.assertRaises(RuntimeError):
                protected.__enter__()
        self.assertEqual(len(self.backend.closed), len(self.backend.handles))

    def test_hash_mismatch_closes_all_handles_without_claim_or_retry(self):
        self.manifest[r"C:\frozen\two.exe"] = "0" * 64
        protected = self.scope()
        with self.assertRaises(ValueError):
            protected.open()
        self.assertEqual(len(self.backend.closed), len(self.backend.handles))
        self.assertEqual(self.backend.created, [])
        with self.assertRaises(RuntimeError):
            protected.open()

    def test_size_and_total_budgets_close_without_mutation(self):
        for options in ({"max_file_bytes": 2}, {"max_total_bytes": 5}):
            with self.subTest(options=options):
                self.backend = FileBackend()
                with self.assertRaises(ValueError):
                    self.scope(**options).open()
                self.assertEqual(len(self.backend.closed), len(self.backend.handles))
                self.assertEqual(self.backend.created, [])

    def test_duplicate_physical_file_identity_is_rejected(self):
        self.backend.identities[r"C:\frozen\two.exe"] = self.backend.identities[r"C:\frozen\one.py"]
        with self.assertRaises(ValueError):
            self.scope().open()
        self.assertEqual(len(self.backend.closed), len(self.backend.handles))

    def test_directory_failure_releases_prior_ancestors(self):
        original = self.backend.open_directory
        def directory(path):
            if path == r"C:\frozen":
                raise ValueError("fixture reparse directory")
            return original(path)
        self.backend.open_directory = directory
        with self.assertRaises(ValueError):
            self.scope().open()
        self.assertEqual(len(self.backend.closed), len(self.backend.handles))
        self.assertEqual(self.backend.created, [])

    def test_nonfixed_root_refused_before_opening_it(self):
        self.backend.check_fixed_root = lambda root: (_ for _ in ()).throw(ValueError("not fixed"))
        with self.assertRaises(ValueError):
            self.scope().open()
        self.assertEqual(self.backend.handles, {})

    def test_changed_size_and_short_reads_are_refused(self):
        for sizes in ((3, 4), (4, 4)):
            with self.subTest(sizes=sizes):
                self.backend = FileBackend()
                self.backend.size = lambda handle, iterator=iter(sizes): next(iterator)
                with self.assertRaises(ValueError):
                    self.scope().open()
                self.assertEqual(len(self.backend.closed), len(self.backend.handles))

    def test_all_known_runtime_outputs_and_pending_variants_refuse_without_writes(self):
        self.assertIn("recorded-draw.bin.thread-samples.bin", self.helper.RUNTIME_LEAVES)
        for leaf in self.helper.RUNTIME_LEAVES:
            for suffix in ("", ".pending"):
                with self.subTest(leaf=leaf, suffix=suffix):
                    self.backend = FileBackend()
                    self.backend.existing.add("C:\\evidence\\run\\" + leaf + suffix)
                    with self.assertRaises(FileExistsError):
                        self.scope().open()
                    self.assertEqual(self.backend.created, [])
                    self.assertEqual(len(self.backend.closed), len(self.backend.handles))

    def test_held_source_read_never_reopens_and_restores_offset(self):
        with self.scope() as protected:
            handle = protected._inputs[r"c:\frozen\one.py"]
            self.backend.positions[handle] = 2
            prior_opens = list(self.backend.events)
            self.assertEqual(protected.read_bytes(r"c:\FROZEN\ONE.py"), b"one")
            self.assertEqual(self.backend.positions[handle], 2)
            self.assertEqual(self.backend.events, prior_opens)
            with self.assertRaises(ValueError):
                protected.read_bytes(r"C:\frozen\absent.py")
            with self.assertRaises(ValueError):
                protected.read_bytes(r"C:\frozen\one.py", max_bytes=2)
        with self.assertRaises(RuntimeError):
            protected.read_bytes(r"C:\frozen\one.py")

    def test_held_read_restores_offset_on_failure(self):
        with self.scope() as protected:
            handle = protected._inputs[r"c:\frozen\one.py"]
            self.backend.positions[handle] = 1
            self.backend.chunks = lambda *_args: (_ for _ in ()).throw(OSError("fixture read failure"))
            with self.assertRaises(OSError):
                protected.read_bytes(r"C:\frozen\one.py")
            self.assertEqual(self.backend.positions[handle], 1)

    def test_one_shot_claim_exact_schema_fixed_leaf_and_handle_lifetime(self):
        with self.scope() as protected:
            receipt = protected.claim_attempt(TOKEN, DIGEST)
            self.assertEqual(receipt, {"kind": "beamrt-runner-attempt-v1", "token": TOKEN, "configDigest": DIGEST})
            self.assertEqual(len(self.backend.created), 1)
            path, image = self.backend.created[0]
            self.assertEqual(path, r"C:\evidence\run\runner-claim.json")
            self.assertEqual(json.loads(image), receipt)
            self.assertEqual(self.backend.closed, [])
            with self.assertRaises(RuntimeError):
                protected.claim_attempt(TOKEN, DIGEST)
        self.assertEqual(len(self.backend.closed), len(self.backend.handles))

    def test_claim_identity_rejects_before_mutating(self):
        with self.scope() as protected:
            for token, digest in ((TOKEN.upper(), DIGEST), (TOKEN[:-1], DIGEST), (TOKEN, "A" * 64), (True, DIGEST)):
                with self.subTest(token=token, digest=digest), self.assertRaises(ValueError):
                    protected.claim_attempt(token, digest)
            self.assertEqual(self.backend.created, [])
            protected.claim_attempt(TOKEN, DIGEST)

    def test_claim_rechecks_freshness_and_refuses_publication_race(self):
        with self.scope() as protected:
            self.backend.existing.add(r"C:\evidence\run\started.json")
            with self.assertRaises(FileExistsError):
                protected.claim_attempt(TOKEN, DIGEST)
            self.assertEqual(self.backend.created, [])
        self.backend = FileBackend()
        with self.scope() as protected:
            self.backend.create_claim = lambda *_args: (_ for _ in ()).throw(FileExistsError("fixture race"))
            with self.assertRaises(FileExistsError):
                protected.claim_attempt(TOKEN, DIGEST)
            with self.assertRaises(RuntimeError):
                protected.claim_attempt(TOKEN, DIGEST)

    def test_caller_exception_releases_handles_but_keeps_consumed_claim(self):
        with self.assertRaisesRegex(RuntimeError, "caller failure"):
            with self.scope() as protected:
                protected.claim_attempt(TOKEN, DIGEST)
                raise RuntimeError("caller failure")
        self.assertEqual(len(self.backend.closed), len(self.backend.handles))
        self.assertEqual(len(self.backend.created), 1)


@unittest.skipUnless(os.name == "nt", "actual Win32 file sharing requires Windows")
class WindowsPhysicalInputContracts(unittest.TestCase):
    def setUp(self):
        self.helper = load_helper()
        self.temporary = tempfile.TemporaryDirectory(prefix="beamrt-input-locks-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.inputs = self.directory / "inputs"
        self.run = self.directory / "run"
        self.inputs.mkdir()
        self.run.mkdir()
        self.source = self.inputs / "frozen.py"
        self.image = b"# held fixture source\nvalue = 17\n"
        self.source.write_bytes(self.image)
        self.manifest = {str(self.source): hashlib.sha256(self.image).hexdigest()}

    def test_real_handle_denies_write_delete_and_ancestor_rename_but_allows_read(self):
        with self.helper.ProtectedInputs(self.manifest, self.run) as protected:
            self.assertEqual(self.source.read_bytes(), self.image)
            self.assertEqual(protected.read_bytes(self.source), self.image)
            for mutation in (lambda: self.source.write_bytes(b"changed"), lambda: self.source.unlink(),
                             lambda: self.source.rename(self.inputs / "renamed.py"),
                             lambda: self.inputs.rename(self.directory / "moved"),
                             lambda: self.run.rename(self.directory / "moved-run")):
                with self.subTest(mutation=mutation), self.assertRaises(OSError):
                    mutation()
            # No directory write ban or changes to an ACL: unrelated outputs work.
            (self.run / "ordinary-fixture-output.txt").write_bytes(b"allowed")
        self.source.write_bytes(b"after scope")
        self.assertEqual(self.source.read_bytes(), b"after scope")

    def test_real_claim_is_crt_readable_immutable_and_not_reusable(self):
        claim = self.run / self.helper.CLAIM_LEAF
        with self.helper.ProtectedInputs(self.manifest, self.run) as protected:
            receipt = protected.claim_attempt(TOKEN, DIGEST)
            self.assertEqual(json.loads(claim.read_bytes()), receipt)
            with self.assertRaises(OSError):
                claim.write_bytes(b"overwrite")
            with self.assertRaises(OSError):
                claim.unlink()
        with self.assertRaises(FileExistsError):
            self.helper.ProtectedInputs(self.manifest, self.run).open()
        self.assertEqual(json.loads(claim.read_bytes()), receipt)

    def test_real_wrong_hash_releases_handles_without_claim(self):
        with self.assertRaises(ValueError):
            self.helper.ProtectedInputs({str(self.source): "0" * 64}, self.run).open()
        self.assertFalse((self.run / self.helper.CLAIM_LEAF).exists())
        self.source.write_bytes(b"released after refusal")

    def test_real_hardlink_aliases_are_refused(self):
        alias = self.inputs / "hardlink.py"
        os.link(self.source, alias)
        manifest = dict(self.manifest)
        manifest[str(alias)] = next(iter(manifest.values()))
        with self.assertRaises(ValueError):
            self.helper.ProtectedInputs(manifest, self.run).open()

    def test_real_reparse_directory_is_refused_when_symlink_privilege_available(self):
        alias = self.directory / "reparse-inputs"
        try:
            os.symlink(self.inputs, alias, target_is_directory=True)
        except OSError as error:
            self.skipTest("directory symlink privilege unavailable: " + str(error))
        with self.assertRaises(ValueError):
            self.helper.ProtectedInputs({str(alias / self.source.name): next(iter(self.manifest.values()))}, self.run).open()

    def test_real_junction_component_is_refused_without_process_tools(self):
        alias = self.directory / "junction-inputs"
        alias.mkdir()
        self.addCleanup(lambda: os.rmdir(alias) if alias.exists() else None)
        backend = self.helper._Win32()
        handle = backend._open(str(alias), 0x40000000, 7, 3, 0x02000000 | 0x00200000)
        ctypes = self.helper.ctypes
        win = self.helper.wintypes
        control = backend.api.DeviceIoControl
        control.argtypes = [win.HANDLE, win.DWORD, ctypes.c_void_p, win.DWORD,
                            ctypes.c_void_p, win.DWORD, ctypes.POINTER(win.DWORD), ctypes.c_void_p]
        control.restype = win.BOOL
        substitute = ("\\??\\" + str(self.inputs)).encode("utf-16-le")
        printed = str(self.inputs).encode("utf-16-le")
        paths = substitute + b"\0\0" + printed + b"\0\0"
        data = struct.pack("<LHHHHHH", 0xA0000003, 8 + len(paths), 0,
                           0, len(substitute), len(substitute) + 2, len(printed)) + paths
        returned = win.DWORD()
        try:
            if not control(handle, 0x000900A4, data, len(data), None, 0, ctypes.byref(returned), None):
                raise backend._error()
        finally:
            backend.close(handle)
        with self.assertRaises(ValueError):
            self.helper.ProtectedInputs({str(alias / self.source.name): next(iter(self.manifest.values()))}, self.run).open()


if __name__ == "__main__":
    unittest.main()
