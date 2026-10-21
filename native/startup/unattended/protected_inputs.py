"""Inert physical-input locks and a machine-only, one-shot runner claim.

No process, game, permission, or human-approval operation lives here. On Windows
the input handles deny subsequent write/delete access, and retained ancestor
directory handles deny rename/deletion. Hashes are read through those handles.
This is not an ACL, a power-loss durability promise, or protection from an
administrator/kernel writer. A failed claim remains consumed on disk.
"""
from __future__ import annotations

from collections.abc import Mapping
import ctypes
from ctypes import wintypes
import hashlib
import json
import ntpath
import os
import re


MAX_FILES = 512
MAX_FILE_BYTES = 1024 ** 3
MAX_TOTAL_BYTES = 2 * 1024 ** 3
READ_CHUNK = 1024 ** 2
CLAIM_LEAF = "runner-claim.json"
RUNTIME_LEAVES = (
    CLAIM_LEAF, "host-claim.json", "process-context.json", "launch-approval.json",
    "started.json", "driver-ack.json", "unattended-events.jsonl", "owner-stop.json",
    "owned-exit.json", "receipt-ready.json", "recorded-draw.bin",
    "recorded-draw.bin.resources-start.bin", "recorded-draw.bin.resources.bin",
    "recorded-draw.bin.threads.bin", "recorded-draw.bin.thread-samples.bin",
    "runner-plan.json", "runner-result.json", "runner-host.log", "fixture-report.bin",
    "fixture-report.bin.done", "fixture-report.bin.resource-report", "fixture-ack-consumed.json", "root.bin",
)
_DEVICE = re.compile(r"(?:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])(?:\..*)?", re.I)


def physical_path(value) -> str:
    """Validate a lexical drive-absolute path without resolving or touching it."""
    value = os.fspath(value)
    if not isinstance(value, str) or not value or len(value) > 32700:
        raise ValueError("bounded text physical path required")
    value = value.replace("/", "\\")
    if not re.match(r"^[A-Za-z]:\\", value) or value.startswith("\\"):
        raise ValueError("drive-absolute local path required; UNC/device paths refused")
    parts = value[3:].split("\\") if len(value) > 3 else []
    for part in parts:
        if not part or part in (".", "..") or part[-1:] in (" ", ".") \
                or any(ord(character) < 32 or character in '<>:"|?*' for character in part) \
                or _DEVICE.fullmatch(part):
            raise ValueError("ambiguous, device, stream, or trailing-alias path refused")
    return value[0].upper() + value[1:]


def _budget(value, limit, description):
    if type(value) is not int or not 1 <= value <= limit:
        raise ValueError(description + " budget refused")
    return value


def validate_manifest(manifest, *, max_file_bytes=MAX_FILE_BYTES,
                      max_total_bytes=MAX_TOTAL_BYTES) -> tuple[tuple[str, str], ...]:
    """Validate an explicit complete file/hash set, including duplicate aliases."""
    _budget(max_file_bytes, MAX_FILE_BYTES, "per-file")
    _budget(max_total_bytes, MAX_TOTAL_BYTES, "total input")
    entries = manifest.items() if isinstance(manifest, Mapping) else manifest
    if isinstance(entries, (str, bytes)):
        raise ValueError("explicit manifest entries required")
    result = []
    seen = set()
    try:
        for entry in entries:
            if not isinstance(entry, (tuple, list)) or len(entry) != 2:
                raise ValueError("manifest entries must be path/hash pairs")
            path, digest = entry
            path = physical_path(path)
            if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
                raise ValueError("lowercase SHA256 required for every input")
            key = path.casefold()
            if key in seen:
                raise ValueError("duplicate or case-alias manifest input refused")
            seen.add(key)
            result.append((path, digest))
            if len(result) > MAX_FILES:
                raise ValueError("input manifest exceeded file budget")
    except TypeError as error:
        raise ValueError("explicit iterable manifest required") from error
    if not result:
        raise ValueError("empty input manifest refused")
    return tuple(result)


def _ancestors(path):
    root = path[:3]
    yield root
    partial = root.rstrip("\\")
    for component in path[3:].split("\\") if len(path) > 3 else ():
        partial += "\\" + component
        yield partial


class _FileInformation(ctypes.Structure):
    _fields_ = [("attributes", wintypes.DWORD), ("created", wintypes.FILETIME),
                ("accessed", wintypes.FILETIME), ("written", wintypes.FILETIME),
                ("volume", wintypes.DWORD), ("sizeHigh", wintypes.DWORD),
                ("sizeLow", wintypes.DWORD), ("links", wintypes.DWORD),
                ("indexHigh", wintypes.DWORD), ("indexLow", wintypes.DWORD)]


class _Win32:
    """Small synchronous Win32 file backend; constructed only by explicit open."""
    def __init__(self):
        if os.name != "nt":
            raise OSError("physical input protection requires Windows")
        self.api = ctypes.WinDLL("kernel32", use_last_error=True)
        signatures = {
            "CreateFileW": ([wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                            ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD,
                            wintypes.HANDLE], wintypes.HANDLE),
            "CloseHandle": ([wintypes.HANDLE], wintypes.BOOL),
            "GetDriveTypeW": ([wintypes.LPCWSTR], wintypes.UINT),
            "GetFileInformationByHandle": ([wintypes.HANDLE, ctypes.POINTER(_FileInformation)], wintypes.BOOL),
            "GetFinalPathNameByHandleW": ([wintypes.HANDLE, wintypes.LPWSTR, wintypes.DWORD, wintypes.DWORD], wintypes.DWORD),
            "GetFileSizeEx": ([wintypes.HANDLE, ctypes.POINTER(ctypes.c_longlong)], wintypes.BOOL),
            "SetFilePointerEx": ([wintypes.HANDLE, ctypes.c_longlong, ctypes.c_void_p, wintypes.DWORD], wintypes.BOOL),
            "ReadFile": ([wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p], wintypes.BOOL),
            "WriteFile": ([wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p], wintypes.BOOL),
            "FlushFileBuffers": ([wintypes.HANDLE], wintypes.BOOL),
            "GetFileAttributesW": ([wintypes.LPCWSTR], wintypes.DWORD),
        }
        for name, (arguments, result) in signatures.items():
            function = getattr(self.api, name)
            function.argtypes, function.restype = arguments, result

    @staticmethod
    def _extended(path):
        return "\\\\?\\" + path

    @staticmethod
    def _error():
        return ctypes.WinError(ctypes.get_last_error())

    def check_fixed_root(self, root):
        if self.api.GetDriveTypeW(root) != 3:  # DRIVE_FIXED, not removable/network.
            raise ValueError("physical input volume is not a fixed local drive")

    def close(self, handle):
        self.api.CloseHandle(handle)

    def _open(self, path, access, share, creation, flags):
        handle = self.api.CreateFileW(self._extended(path), access, share, None, creation, flags, None)
        if handle == ctypes.c_void_p(-1).value:
            raise self._error()
        return handle

    def _verify(self, handle, path, directory):
        information = _FileInformation()
        if not self.api.GetFileInformationByHandle(handle, ctypes.byref(information)):
            raise self._error()
        if information.attributes & 0x400 or bool(information.attributes & 0x10) != directory:
            raise ValueError("reparse or unexpected physical input type refused")
        buffer = ctypes.create_unicode_buffer(32768)
        size = self.api.GetFinalPathNameByHandleW(handle, buffer, len(buffer), 0)
        if not size or size >= len(buffer):
            raise self._error() if not size else ValueError("final physical path exceeded budget")
        final = buffer.value
        if not final.startswith("\\\\?\\") or final[4:].casefold() != path.casefold():
            raise ValueError("resolved physical input path differs from the explicit path")
        return information.volume, information.indexHigh, information.indexLow

    def open_directory(self, path):
        # READ_ATTRIBUTES alone does not participate in ordinary sharing checks
        # strongly enough to stop an empty directory rename on Windows. Request
        # LIST_DIRECTORY too, while still allowing unrelated child-file writes.
        handle = self._open(path, 0x1 | 0x80 | 0x100000, 3, 3, 0x02000000 | 0x00200000)
        try:
            self._verify(handle, path, True)
            return handle
        except BaseException:
            self.close(handle)
            raise

    def open_input(self, path):
        handle = self._open(path, 0x80000000, 1, 3, 0x00200000)
        try:
            identity = self._verify(handle, path, False)
            return handle, identity
        except BaseException:
            self.close(handle)
            raise

    def size(self, handle):
        size = ctypes.c_longlong()
        if not self.api.GetFileSizeEx(handle, ctypes.byref(size)):
            raise self._error()
        return size.value

    def position(self, handle):
        position = ctypes.c_longlong()
        if not self.api.SetFilePointerEx(handle, 0, ctypes.byref(position), 1):
            raise self._error()
        return position.value

    def seek(self, handle, position):
        if not self.api.SetFilePointerEx(handle, position, None, 0):
            raise self._error()

    def chunks(self, handle, maximum):
        if not self.api.SetFilePointerEx(handle, 0, None, 0):
            raise self._error()
        consumed = 0
        while True:
            capacity = min(READ_CHUNK, maximum - consumed + 1)
            buffer = ctypes.create_string_buffer(capacity)
            read = wintypes.DWORD()
            if not self.api.ReadFile(handle, buffer, capacity, ctypes.byref(read), None):
                raise self._error()
            if not read.value:
                return
            consumed += read.value
            if consumed > maximum:
                raise ValueError("held input exceeded read budget")
            yield buffer.raw[:read.value]

    def exists(self, path):
        if self.api.GetFileAttributesW(self._extended(path)) != 0xFFFFFFFF:
            return True
        error = ctypes.get_last_error()
        if error == 2:  # ERROR_FILE_NOT_FOUND only; parent is held and must exist.
            return False
        raise ctypes.WinError(error)

    def create_claim(self, path, image):
        handle = self._open(path, 0x80000000 | 0x40000000, 1, 1, 0x00200000)
        try:
            self._verify(handle, path, False)
            written = wintypes.DWORD()
            if not self.api.WriteFile(handle, image, len(image), ctypes.byref(written), None):
                raise self._error()
            if written.value != len(image):
                raise OSError("short one-shot claim write")
            if not self.api.FlushFileBuffers(handle):
                raise self._error()
            if b"".join(self.chunks(handle, 4096)) != image:
                raise ValueError("one-shot claim readback differed")
            return handle
        except BaseException:
            self.close(handle)
            # A partial CREATE_NEW artifact is deliberately retained, not retried.
            raise


class ProtectedInputs:
    """Retain verified inputs and physical ancestors for one bounded caller scope.

    .open() and .claim_attempt() never launch anything. .digests returns a copy.
    The private backend seam exists for portable deterministic contract fixtures.
    The caller must finish all users of these paths before leaving this scope.
    """
    def __init__(self, manifest, run_directory, *, max_file_bytes=MAX_FILE_BYTES,
                 max_total_bytes=MAX_TOTAL_BYTES, _backend=None):
        self.manifest = validate_manifest(manifest, max_file_bytes=max_file_bytes,
                                          max_total_bytes=max_total_bytes)
        self.run_directory = physical_path(run_directory)
        if len(self.run_directory) == 3:
            raise ValueError("drive root is not a scoped run directory")
        self.max_file_bytes, self.max_total_bytes = max_file_bytes, max_total_bytes
        self._backend = _backend
        self._state, self._entered, self._attempted = "new", False, False
        self._handles, self._directories, self._digests = [], set(), {}
        self._inputs = {}

    @property
    def digests(self):
        if self._state != "open":
            raise RuntimeError("input protection is not open")
        return dict(self._digests)

    def _hold_directory(self, directory):
        for ancestor in _ancestors(directory):
            key = ancestor.casefold()
            if key not in self._directories:
                if len(ancestor) == 3:
                    self._backend.check_fixed_root(ancestor)
                self._handles.append(self._backend.open_directory(ancestor))
                self._directories.add(key)

    def _require_fresh(self):
        for leaf in RUNTIME_LEAVES:
            for candidate in (leaf, leaf + ".pending"):
                if self._backend.exists(ntpath.join(self.run_directory, candidate)):
                    raise FileExistsError("existing or unverifiable runtime output refused: " + candidate)

    def open(self):
        if self._state == "open":
            return self
        if self._state != "new":
            raise RuntimeError("input protection cannot be reopened")
        try:
            self._backend = self._backend or _Win32()
            self._hold_directory(self.run_directory)
            identities = set()
            total = 0
            for path, expected in self.manifest:
                self._hold_directory(ntpath.dirname(path))
                handle, identity = self._backend.open_input(path)
                self._handles.append(handle)
                if identity in identities:
                    raise ValueError("duplicate physical input identity refused")
                identities.add(identity)
                before = self._backend.size(handle)
                if not 0 <= before <= self.max_file_bytes or total + before > self.max_total_bytes:
                    raise ValueError("held input size budget refused")
                digest = hashlib.sha256()
                consumed = 0
                for chunk in self._backend.chunks(handle, self.max_file_bytes):
                    consumed += len(chunk)
                    if consumed > before or total + consumed > self.max_total_bytes:
                        raise ValueError("held input changed or exceeded total budget")
                    digest.update(chunk)
                if consumed != before or self._backend.size(handle) != before:
                    raise ValueError("held input size changed during verification")
                if digest.hexdigest() != expected:
                    raise ValueError("held input SHA256 differs from the frozen manifest")
                self._digests[path] = digest.hexdigest()
                self._inputs[path.casefold()] = handle
                total += consumed
            self._require_fresh()
            self._state = "open"
            return self
        except BaseException:
            self.close()
            raise

    def read_bytes(self, path, *, max_bytes=READ_CHUNK) -> bytes:
        """Read only an already-held input, without a path reopen or stale pyc."""
        if self._state != "open":
            raise RuntimeError("input protection is not open")
        _budget(max_bytes, MAX_FILE_BYTES, "held read")
        key = physical_path(path).casefold()
        if key not in self._inputs:
            raise ValueError("read requested for an unheld input")
        handle = self._inputs[key]
        if self._backend.size(handle) > max_bytes:
            raise ValueError("held input exceeds requested read budget")
        position = self._backend.position(handle)
        try:
            return b"".join(self._backend.chunks(handle, max_bytes))
        finally:
            self._backend.seek(handle, position)

    def claim_attempt(self, token: str, config_digest: str) -> dict:
        if self._state != "open" or self._attempted:
            raise RuntimeError("one-shot claim requires an open, unconsumed scope")
        if not isinstance(token, str) or not re.fullmatch(r"[0-9a-f]{32}", token) \
                or not isinstance(config_digest, str) or not re.fullmatch(r"[0-9a-f]{64}", config_digest):
            raise ValueError("explicit lowercase token and configuration SHA256 required")
        self._require_fresh()
        self._attempted = True
        receipt = {"kind": "beamrt-runner-attempt-v1", "token": token, "configDigest": config_digest}
        image = (json.dumps(receipt, separators=(",", ":")) + "\n").encode("ascii")
        handle = self._backend.create_claim(ntpath.join(self.run_directory, CLAIM_LEAF), image)
        self._handles.append(handle)
        return receipt

    def close(self):
        while self._handles:
            self._backend.close(self._handles.pop())
        self._directories.clear()
        self._digests.clear()
        self._inputs.clear()
        self._state, self._entered = "closed", False

    def __enter__(self):
        if self._entered:
            raise RuntimeError("nested input-protection scopes refused")
        self.open()
        self._entered = True
        return self

    def __exit__(self, _kind, _error, _traceback):
        self.close()
