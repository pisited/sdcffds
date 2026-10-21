"""Inert, bounded bulk leases over an explicitly inventoried physical file set.

Dependencies are deliberately injected. The caller must supply its frozen,
held-source-loaded ProtectedInputs and Win32 backend factories, not an import of
an unverified helper. Each old ProtectedInputs scope still has its original
512-file limit; this coordinator holds all scopes together and enforces one
cross-scope identity and byte budget. It does not claim, launch, or stop a
process, and an inventory checkpoint is not an atomic namespace seal.
"""
from __future__ import annotations

from collections.abc import Mapping
import os
import re


MAX_INPUTS = 8192
BATCH_FILES = 512
MAX_FILE_BYTES = 1024 ** 3
MAX_TOTAL_BYTES = 2 * 1024 ** 3
_DEVICE = re.compile(r"(?:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])(?:\..*)?", re.I)


def _physical_path(value):
    """Canonicalize only spelling; do not resolve, read, or open the path."""
    value = os.fspath(value)
    if not isinstance(value, str) or not value or len(value) > 32700:
        raise ValueError("bounded text physical path required")
    value = value.replace("/", "\\")
    if not re.match(r"^[A-Za-z]:\\", value) or value.startswith("\\"):
        raise ValueError("drive-absolute local physical path required")
    for part in value[3:].split("\\") if len(value) > 3 else ():
        if not part or part in (".", "..") or part[-1:] in (" ", ".") \
                or any(ord(character) < 32 or character in '<>:"|?*' for character in part) \
                or _DEVICE.fullmatch(part):
            raise ValueError("ambiguous, device, stream, or trailing-alias path refused")
    return value[0].upper() + value[1:]


def _manifest_snapshot(manifest):
    if not isinstance(manifest, Mapping):
        raise ValueError("explicit physical path/hash mapping required")
    entries, seen = [], set()
    for path, digest in manifest.items():
        path = _physical_path(path)
        if len(path) == 3:
            raise ValueError("a drive root is not a physical input file")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("lowercase SHA256 required for every physical input")
        key = path.casefold()
        if key in seen:
            raise ValueError("duplicate or case-alias physical input refused")
        seen.add(key)
        entries.append((path, digest))
        if len(entries) > MAX_INPUTS:
            raise ValueError("bulk physical input count exceeded budget")
    if not entries:
        raise ValueError("empty physical input coverage refused")
    return tuple(entries)


class _SharedBudgetBackend:
    """One backend and accounting ledger shared by every retained old scope."""
    def __init__(self, backend):
        self._backend = backend
        self._handles = {}
        self._inputs = {}
        self._identities = set()
        self._announced_bytes = 0
        self._verified_bytes = 0

    def _retain(self, handle):
        if handle in self._handles:
            raise ValueError("backend returned a duplicate live handle")
        self._handles[handle] = None
        return handle

    def check_fixed_root(self, root):
        return self._backend.check_fixed_root(root)

    def open_directory(self, path):
        return self._retain(self._backend.open_directory(path))

    def open_input(self, path):
        handle, identity = self._backend.open_input(path)
        self._retain(handle)
        try:
            if identity in self._identities:
                raise ValueError("duplicate physical input identity across coverage scopes refused")
            self._identities.add(identity)
            self._inputs[handle] = {"size": None, "verified": False}
            return handle, identity
        except BaseException:
            self.close(handle)  # The old scope has not received this handle yet.
            raise

    def size(self, handle):
        size = self._backend.size(handle)
        if type(size) is not int or not 0 <= size <= MAX_FILE_BYTES:
            raise ValueError("bulk held input per-file byte budget refused")
        item = self._inputs[handle]
        if item["size"] is None:
            if self._announced_bytes + size > MAX_TOTAL_BYTES:
                raise ValueError("bulk held input cumulative byte budget refused")
            item["size"] = size
            self._announced_bytes += size
        elif item["size"] != size:
            raise ValueError("bulk held input size changed during its lease")
        return size

    def chunks(self, handle, maximum):
        item = self._inputs[handle]
        if item["size"] is None:
            raise ValueError("held input size must be checked before reading")
        first_verification = not item["verified"]
        consumed = 0
        for chunk in self._backend.chunks(handle, maximum):
            consumed += len(chunk)
            if consumed > item["size"] or consumed > maximum \
                    or (first_verification and self._verified_bytes + consumed > MAX_TOTAL_BYTES):
                raise ValueError("bulk held read changed or exceeded cumulative byte budget")
            yield chunk
        if consumed != item["size"]:
            raise ValueError("bulk held input read did not match its checked size")
        if first_verification:
            self._verified_bytes += consumed
            item["verified"] = True

    def position(self, handle):
        return self._backend.position(handle)

    def seek(self, handle, position):
        return self._backend.seek(handle, position)

    def exists(self, path):
        return self._backend.exists(path)

    def close(self, handle):
        if handle in self._handles:
            # Make one close attempt for each actual owned handle. Never close
            # an already-closed numeric value that could have been reused.
            del self._handles[handle]
            self._inputs.pop(handle, None)
            self._backend.close(handle)

    def close_remaining(self):
        first_error = None
        for handle in tuple(reversed(self._handles)):
            try:
                self.close(handle)
            except BaseException as error:
                if first_error is None:
                    first_error = error
        if first_error is not None:
            raise first_error


class CoverageLease:
    """Hold up to 8192 explicit inputs, at most 1 GiB each and 2 GiB total.

    inventory_check must return True (not merely a truthy value) before opening,
    after every scope is held, and at requested checkpoints. A failed open or
    checkpoint permanently closes the lease, including a partially opened
    scope. The supplied factories must implement the existing ProtectedInputs
    constructor/backend interface. No factory has a default or is imported here.
    """
    def __init__(self, manifest, run_directory, *, protector_factory,
                 backend_factory, inventory_check):
        self._entries = _manifest_snapshot(manifest)
        self._run_directory = _physical_path(run_directory)
        if len(self._run_directory) == 3:
            raise ValueError("drive root is not a scoped run directory")
        for factory in (protector_factory, backend_factory, inventory_check):
            if not callable(factory):
                raise ValueError("explicit callable coverage dependencies required")
        self._protector_factory = protector_factory
        self._backend_factory = backend_factory
        self._inventory_check = inventory_check
        self._state, self._entered = "new", False
        self._backend = None
        self._scopes, self._routes, self._digests = [], {}, {}

    @property
    def digests(self):
        if self._state != "open":
            raise RuntimeError("physical input coverage is not open")
        return dict(self._digests)

    def _check_inventory(self):
        if self._inventory_check() is not True:
            raise ValueError("physical input inventory checkpoint refused")

    def open(self):
        if self._state == "open":
            return self
        if self._state != "new":
            raise RuntimeError("physical input coverage cannot be reopened")
        try:
            self._check_inventory()
            self._backend = _SharedBudgetBackend(self._backend_factory())
            for offset in range(0, len(self._entries), BATCH_FILES):
                manifest = dict(self._entries[offset:offset + BATCH_FILES])
                scope = self._protector_factory(
                    manifest, self._run_directory,
                    max_file_bytes=MAX_FILE_BYTES, max_total_bytes=MAX_TOTAL_BYTES,
                    _backend=self._backend)
                self._scopes.append(scope)  # Include a subsequent partial open.
                scope.open()
                observed = scope.digests
                if observed != manifest:
                    raise ValueError("held scope coverage differs from the frozen manifest")
                self._digests.update(observed)
                self._routes.update((path.casefold(), scope) for path in manifest)
            self._check_inventory()
            self._state = "open"
            return self
        except BaseException:
            try:
                self.close()
            except BaseException:
                pass  # Preserve the original refusal after attempting all closes.
            raise

    def verify_inventory(self):
        if self._state != "open":
            raise RuntimeError("physical input coverage is not open")
        try:
            self._check_inventory()
            return True
        except BaseException:
            try:
                self.close()
            except BaseException:
                pass
            raise

    def read_bytes(self, path, *, max_bytes):
        """Read a held file through its original scope, with an explicit budget."""
        if self._state != "open":
            raise RuntimeError("physical input coverage is not open")
        if type(max_bytes) is not int or not 1 <= max_bytes <= MAX_FILE_BYTES:
            raise ValueError("explicit bounded held read budget required")
        path = _physical_path(path)
        scope = self._routes.get(path.casefold())
        if scope is None:
            raise ValueError("read requested for an input outside held coverage")
        return scope.read_bytes(path, max_bytes=max_bytes)

    def close(self):
        first_error = None
        while self._scopes:
            try:
                self._scopes.pop().close()
            except BaseException as error:
                if first_error is None:
                    first_error = error
        if self._backend is not None:
            try:
                self._backend.close_remaining()
            except BaseException as error:
                if first_error is None:
                    first_error = error
        self._routes.clear()
        self._digests.clear()
        self._state, self._entered = "closed", False
        if first_error is not None:
            raise first_error

    def __enter__(self):
        if self._entered:
            raise RuntimeError("nested physical coverage scopes refused")
        self.open()
        self._entered = True
        return self

    def __exit__(self, _kind, _error, _traceback):
        self.close()
