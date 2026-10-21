"""Inert exact-child ownership outside the native startup host.

An explicit factory creates a fresh suspended child. Private process/thread
masters are never imported, looked up by PID, or exposed to the startup host.
The watcher exists in this outer process before a host can be launched. This
protects against that host exiting or hanging, not against the outer process,
OS, or scheduler failing. A normal-request publisher runs separately so blocked
file I/O cannot hold the watchdog's grace clock.
"""
from __future__ import annotations

import ctypes
from ctypes import wintypes
from dataclasses import dataclass
import math
import ntpath
import os
import re
import struct
import subprocess
import threading
import time


FORCED_EXIT_CODE = 0x42525446
PROCESS_SETUP_RIGHTS = 0x0008 | 0x0010 | 0x0020 | 0x0400 | 0x100000
THREAD_SETUP_RIGHTS = 0x0040 | 0x100000
CHANNEL_MAGIC = b"BRTEXT1\0"
CHANNEL_BYTES = 512
CHANNEL_ABI = 1
IPC_COUNTS = frozenset((1, 3, 5, 9, 12, 14))
IPC_RIGHTS = (2, 2, 2, 2, 2, 4, 2, 2, 2, 2, 2, 2, 2, 2)
_HEADER = struct.Struct("<8sII16s32sIIQIIIIQQQQ")


def _seconds(value, maximum, description):
    if type(value) not in (int, float) or not math.isfinite(value) or not 0 < value <= maximum:
        raise ValueError(description + " outside bounded ownership contract")
    return float(value)


def _token(value):
    if type(value) is not str or not re.fullmatch(r"[0-9a-f]{32}", value):
        raise ValueError("explicit lowercase run token required")
    return value


def _absolute_executable(value):
    if type(value) is not str or not re.match(r"^[A-Za-z]:[\\/]", value) or "\0" in value \
            or not value.lower().endswith(".exe") or len(value) > 32700:
        raise ValueError("explicit drive-absolute executable required")
    value = value.replace("/", "\\")
    if any(not item or item in (".", "..") or item.endswith((" ", ".")) or
           any(ord(char) < 32 or char in '<>:"|?*' for char in item)
           for item in value[3:].split("\\")):
        raise ValueError("ambiguous executable path refused")
    return value


def _absolute_directory(value):
    if type(value) is not str or not re.match(r"^[A-Za-z]:[\\/]", value) or "\0" in value \
            or len(value) > 32700:
        raise ValueError("explicit drive-absolute working directory required")
    value = value.replace("/", "\\")
    if len(value) > 3 and any(not item or item in (".", "..") or item.endswith((" ", ".")) or
            any(ord(char) < 32 or char in '<>:"|?*' for char in item)
            for item in value[3:].split("\\")):
        raise ValueError("ambiguous working directory refused")
    return value


def channel_image(token, config_digest, process_id, thread_id, creation_tick,
                  overall_ms, grace_ms, termination_wait_ms, ipc_count, handles):
    """Build the strict fixed-size setup channel; identity is never a PID lease."""
    _token(token)
    if any(type(value) is not int or not 1 <= value <= 0xFFFFFFFF for value in (process_id, thread_id)):
        raise ValueError("actual created process/thread IDs required")
    if type(config_digest) is not str or not re.fullmatch(r"[0-9a-f]{64}", config_digest):
        raise ValueError("explicit reviewed configuration digest required")
    if type(creation_tick) is not int or not 0 <= creation_tick <= 0xFFFFFFFFFFFFFFFF \
            or type(ipc_count) is not int or ipc_count not in IPC_COUNTS:
        raise ValueError("creation clock or IPC-count contract refused")
    for value, maximum in ((overall_ms, 480000), (grace_ms, 30000), (termination_wait_ms, 10000)):
        if type(value) is not int or not 1 <= value <= maximum:
            raise ValueError("integer shared-channel deadline refused")
    if type(handles) is not tuple or len(handles) != 4 or any(type(handle) is not int or
            not 1 <= handle < 0xFFFFFFFFFFFFFFF0 for handle in handles) or len(set(handles)) != 4:
        raise ValueError("explicit unique inherited setup handles required")
    image = bytearray(CHANNEL_BYTES)
    _HEADER.pack_into(image, 0, CHANNEL_MAGIC, CHANNEL_BYTES, CHANNEL_ABI, bytes.fromhex(token),
                      bytes.fromhex(config_digest), process_id, thread_id, creation_tick,
                      overall_ms, grace_ms, termination_wait_ms, ipc_count, *handles)
    struct.pack_into("<IIII", image, 128, 0, 0xFFFFFFFF, 0xFFFFFFFF, 0)
    return bytes(image)


@dataclass(frozen=True)
class HostCapabilities:
    """Only reduced-right, inheritable duplicates. No master handle is present."""
    process_handle: int
    thread_handle: int
    mapping_handle: int
    ready_event: int
    grant_event: int

    @property
    def handle_list(self):
        return (self.process_handle, self.thread_handle, self.mapping_handle, self.ready_event, self.grant_event)


class OwnerCreationError(RuntimeError):
    """Controlled post-Create failure retaining the actual factory capability.

    The caller must retain this owner and its input locks until exact exit can
    be observed. The capability contains no reopened/adopted process handle.
    """
    def __init__(self, message, owner):
        super().__init__(message)
        self.owner = owner


class _StartupInfo(ctypes.Structure):
    _fields_ = [("cb", wintypes.DWORD), ("lpReserved", wintypes.LPWSTR),
                ("lpDesktop", wintypes.LPWSTR), ("lpTitle", wintypes.LPWSTR),
                ("dwX", wintypes.DWORD), ("dwY", wintypes.DWORD),
                ("dwXSize", wintypes.DWORD), ("dwYSize", wintypes.DWORD),
                ("dwXCountChars", wintypes.DWORD), ("dwYCountChars", wintypes.DWORD),
                ("dwFillAttribute", wintypes.DWORD), ("dwFlags", wintypes.DWORD),
                ("wShowWindow", wintypes.WORD), ("cbReserved2", wintypes.WORD),
                ("lpReserved2", ctypes.c_void_p), ("hStdInput", wintypes.HANDLE),
                ("hStdOutput", wintypes.HANDLE), ("hStdError", wintypes.HANDLE)]


class _ProcessInformation(ctypes.Structure):
    _fields_ = [("hProcess", wintypes.HANDLE), ("hThread", wintypes.HANDLE),
                ("dwProcessId", wintypes.DWORD), ("dwThreadId", wintypes.DWORD)]


class _Win32:
    """Small private backend; never calls OpenProcess or accepts a process PID."""
    def __init__(self):
        if os.name != "nt":
            raise OSError("exact-child creation requires Windows")
        self.api = ctypes.WinDLL("kernel32", use_last_error=True)
        signatures = {
            "CreateProcessW": ([wintypes.LPCWSTR, wintypes.LPWSTR, ctypes.c_void_p, ctypes.c_void_p,
                                wintypes.BOOL, wintypes.DWORD, ctypes.c_void_p, wintypes.LPCWSTR,
                                ctypes.POINTER(_StartupInfo), ctypes.POINTER(_ProcessInformation)], wintypes.BOOL),
            "GetCurrentProcess": ([], wintypes.HANDLE),
            "DuplicateHandle": ([wintypes.HANDLE, wintypes.HANDLE, wintypes.HANDLE,
                                 ctypes.POINTER(wintypes.HANDLE), wintypes.DWORD, wintypes.BOOL, wintypes.DWORD], wintypes.BOOL),
            "CloseHandle": ([wintypes.HANDLE], wintypes.BOOL),
            "GetProcessId": ([wintypes.HANDLE], wintypes.DWORD),
            "GetThreadId": ([wintypes.HANDLE], wintypes.DWORD),
            "GetProcessIdOfThread": ([wintypes.HANDLE], wintypes.DWORD),
            "WaitForSingleObject": ([wintypes.HANDLE, wintypes.DWORD], wintypes.DWORD),
            "GetExitCodeProcess": ([wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)], wintypes.BOOL),
            "ResumeThread": ([wintypes.HANDLE], wintypes.DWORD),
            "TerminateProcess": ([wintypes.HANDLE, wintypes.UINT], wintypes.BOOL),
            "CreateFileMappingW": ([wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD,
                                     wintypes.DWORD, wintypes.LPCWSTR], wintypes.HANDLE),
            "MapViewOfFile": ([wintypes.HANDLE, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD,
                                ctypes.c_size_t], ctypes.c_void_p),
            "UnmapViewOfFile": ([ctypes.c_void_p], wintypes.BOOL),
            "CreateEventW": ([ctypes.c_void_p, wintypes.BOOL, wintypes.BOOL, wintypes.LPCWSTR], wintypes.HANDLE),
            "SetEvent": ([wintypes.HANDLE], wintypes.BOOL),
            "GetTickCount64": ([], ctypes.c_uint64),
        }
        for name, (arguments, result) in signatures.items():
            function = getattr(self.api, name)
            function.argtypes, function.restype = arguments, result

    @staticmethod
    def error():
        return ctypes.WinError(ctypes.get_last_error())

    def create_suspended(self, executable, arguments, directory):
        command = subprocess.list2cmdline((executable, *arguments))
        if len(command) >= 32767:
            raise ValueError("Windows command line exceeded budget")
        writable = ctypes.create_unicode_buffer(command)
        startup, created = _StartupInfo(), _ProcessInformation()
        startup.cb, startup.dwFlags, startup.wShowWindow = ctypes.sizeof(startup), 1, 0
        if not self.api.CreateProcessW(executable, writable, None, None, False, 0x4 | 0x08000000,
                                       None, directory, ctypes.byref(startup), ctypes.byref(created)):
            raise self.error()
        return int(created.hProcess), int(created.hThread), created.dwProcessId, created.dwThreadId

    def tick_ms(self):
        return int(self.api.GetTickCount64())

    def close(self, handle):
        self.api.CloseHandle(handle)

    def identity(self, process, thread):
        pid, tid, thread_pid = self.api.GetProcessId(process), self.api.GetThreadId(thread), self.api.GetProcessIdOfThread(thread)
        if not pid or not tid or not thread_pid:
            raise self.error()
        return pid, tid, thread_pid

    def observe_exit(self, process, timeout_ms=0):
        waited = self.api.WaitForSingleObject(process, timeout_ms)
        if waited == 0x102:
            return None
        if waited != 0:
            raise self.error() if waited == 0xFFFFFFFF else OSError("unexpected retained-handle wait result")
        code = wintypes.DWORD()
        if not self.api.GetExitCodeProcess(process, ctypes.byref(code)):
            raise self.error()
        return code.value  # 259 is valid only after this signaled wait.

    def resume(self, thread):
        result = self.api.ResumeThread(thread)
        if result == 0xFFFFFFFF:
            raise self.error()
        return result

    def terminate(self, process):
        if not self.api.TerminateProcess(process, FORCED_EXIT_CODE):
            raise self.error()

    def duplicate(self, source, rights):
        result = wintypes.HANDLE()
        current = self.api.GetCurrentProcess()
        if not self.api.DuplicateHandle(current, source, current, ctypes.byref(result), rights, True, 0):
            raise self.error()
        return int(result.value)

    def relay(self, host_process, source, child_process, rights):
        result = wintypes.HANDLE()
        if not self.api.DuplicateHandle(host_process, source, child_process,
                                        ctypes.byref(result), rights, False, 0):
            raise self.error()
        return int(result.value)

    def create_channel(self, image):
        handles, view = [], None
        try:
            mapping = self.api.CreateFileMappingW(ctypes.c_void_p(-1), None, 0x04, 0, len(image), None)
            if not mapping:
                raise self.error()
            handles.append(int(mapping))
            view = self.api.MapViewOfFile(mapping, 0x0002 | 0x0004, 0, 0, len(image))
            if not view:
                raise self.error()
            ctypes.memmove(view, image, len(image))
            for _ in range(2):
                event = self.api.CreateEventW(None, False, False, None)
                if not event:
                    raise self.error()
                handles.append(int(event))
            return (*handles, int(view))
        except BaseException:
            if view:
                self.api.UnmapViewOfFile(view)
            for handle in reversed(handles):
                self.close(handle)
            raise

    def read_channel(self, view):
        return ctypes.string_at(view, CHANNEL_BYTES)

    def write_channel(self, view, image):
        if type(image) is not bytes or len(image) != CHANNEL_BYTES:
            raise ValueError("exact shared-channel image required")
        # An aligned DWORD store is atomic on the required Windows x64 target.
        # Publish it last, then SetEvent supplies the synchronization barrier.
        ctypes.memmove(view, image[:128], 128)
        ctypes.memmove(view + 132, image[132:], CHANNEL_BYTES - 132)
        ctypes.c_uint32.from_address(view + 128).value = struct.unpack_from("<I", image, 128)[0]

    def ready(self, event):
        value = self.api.WaitForSingleObject(event, 0)
        if value not in (0, 0x102):
            raise self.error() if value == 0xFFFFFFFF else OSError("unexpected setup-ready wait")
        return value == 0

    def grant(self, event):
        if not self.api.SetEvent(event):
            raise self.error()

    def unmap(self, view):
        self.api.UnmapViewOfFile(view)


class OuterChildOwner:
    """Create-only outer capability. Instances are one shot and not adoptable.

    The default watcher is a thread in the independent runner process, not in
    the native host. `_backend` and `_start_watcher` are deterministic test
    seams; production callers must not replace or suppress ownership servicing.
    """
    def __init__(self):
        raise TypeError("use explicit OuterChildOwner.create")

    @classmethod
    def create(cls, executable, arguments, working_directory, *, token,
               overall_seconds, normal_grace_seconds, force_close_authorized,
               normal_request, config_digest, expected_ipc_count,
               termination_wait_seconds=5, _backend=None,
               _clock=time.monotonic, _sleep=time.sleep, _start_watcher=True,
               _process_factory=None):
        executable = _absolute_executable(executable)
        if type(arguments) not in (tuple, list) or any(type(value) is not str or "\0" in value for value in arguments):
            raise ValueError("explicit exact argument vector required")
        working_directory = _absolute_directory(working_directory)
        _token(token)
        if type(config_digest) is not str or not re.fullmatch(r"[0-9a-f]{64}", config_digest) \
                or type(expected_ipc_count) is not int or expected_ipc_count not in IPC_COUNTS:
            raise ValueError("explicit reviewed configuration digest and IPC profile required")
        overall = _seconds(overall_seconds, 480, "overall timeout")
        grace = _seconds(normal_grace_seconds, 30, "normal grace")
        termination_wait = _seconds(termination_wait_seconds, 10, "termination wait")
        if any(int(value * 1000) < 1 for value in (overall, grace, termination_wait)):
            raise ValueError("shared ownership limits require at least one millisecond")
        if termination_wait != 5:
            raise ValueError("shared outer-owner termination wait is fixed at 5000 milliseconds")
        if type(force_close_authorized) is not bool or not callable(normal_request) or type(_start_watcher) is not bool:
            raise ValueError("explicit force policy, normal publisher and watcher required")
        owner = object.__new__(cls)
        owner._lock, owner._wake = threading.RLock(), threading.Event()
        owner._backend, owner._clock, owner._sleep = _backend or _Win32(), _clock, _sleep
        owner._overall, owner._grace, owner._termination_wait = overall, grace, termination_wait
        owner._force_authorized, owner._normal_request = force_close_authorized, normal_request
        owner._token, owner._process, owner._thread = token, None, None
        owner._config_digest, owner._ipc_count = config_digest, expected_ipc_count
        owner._host, owner._host_attempted = None, False
        owner._process_factory = _process_factory or subprocess.Popen
        owner._watcher, owner._normal_worker, owner._capabilities = None, None, None
        owner._channel, owner._expected_channel = None, None
        owner._stop, owner._closed, owner._last = False, False, None
        owner._normal_at, owner._terminal = None, False
        owner._report = {
            "expectedPid": 0, "expectedThreadId": 0, "processExitVerified": False,
            "exitCode": None, "resumeAttempted": False, "resumed": False,
            "resumeGranted": False, "normalRequested": False, "normalQueued": False,
            "normalCompleted": False, "normalSucceeded": False, "normalError": None,
            "normalRequestMilliseconds": None, "forceAttempted": False,
            "forceSucceeded": False, "forceError": None, "forceAttemptMilliseconds": None,
            "neverExecutedCleanupAttempted": False, "neverExecutedCleanupSucceeded": False,
            "neverExecutedCleanupError": None, "observationError": None,
            "elapsedMilliseconds": 0, "setupReady": False,
            "forceUnauthorizedAfterGrace": False, "watcherError": None,
            "hostObservationError": None,
        }
        owner._created_at = owner._now()
        try:
            owner._creation_tick = owner._backend.tick_ms()
            actual = owner._backend.create_suspended(executable, tuple(arguments), working_directory)
            owner._process, owner._thread = actual[:2]
            owner._report["expectedPid"], owner._report["expectedThreadId"] = actual[2:]
            if any(type(value) is not int or not 1 <= value <= 0xFFFFFFFF for value in actual[2:]) \
                    or not owner._process or not owner._thread:
                raise ValueError("created exact-child identity is invalid")
            if owner._backend.identity(owner._process, owner._thread) != (actual[2], actual[3], actual[2]):
                raise ValueError("retained created process/thread identities disagree")
            if _start_watcher:
                owner._watcher = threading.Thread(target=owner._watch, name="BeamRT exact-child owner", daemon=True)
                owner._watcher.start()
            return owner
        except BaseException as error:
            if owner._process:
                owner._cleanup_never_executed()
                if not owner._report["processExitVerified"]:
                    raise OwnerCreationError("post-Create setup failed; exact child exit unconfirmed: " + str(error), owner) from error
            owner._close_handles()
            raise

    def _now(self):
        value = self._clock()
        if type(value) not in (int, float) or not math.isfinite(value) or value < 0 or (self._last is not None and value < self._last):
            raise ValueError("invalid or regressing outer-owner clock")
        self._last = value
        return value

    def _elapsed(self):
        value = self._now() - self._created_at
        self._report["elapsedMilliseconds"] = int(value * 1000)
        return value

    def _observe_exit(self, timeout_ms=0):
        if self._report["processExitVerified"]:
            return True
        try:
            code = self._backend.observe_exit(self._process, timeout_ms)
            if code is not None:
                if type(code) is not int or not 0 <= code <= 0xFFFFFFFF:
                    raise ValueError("retained-handle exit code refused")
                self._report["processExitVerified"], self._report["exitCode"] = True, code
                self._report["observationError"] = None
                self._terminal = True
                return True
        except (OSError, ValueError) as error:
            self._report["observationError"] = str(error)
        return False

    def _cleanup_never_executed(self):
        if self._report["resumeAttempted"] or self._report["neverExecutedCleanupAttempted"] or self._observe_exit():
            return
        if self._report["observationError"] is not None:
            self._terminal = True
            return
        self._report["neverExecutedCleanupAttempted"] = True
        try:
            self._backend.terminate(self._process)
            self._report["neverExecutedCleanupSucceeded"] = True
            self._observe_exit(int(self._termination_wait * 1000))
        except (OSError, ValueError) as error:
            self._report["neverExecutedCleanupError"] = str(error)
        self._terminal = True

    def _publish_normal(self):
        try:
            succeeded = self._normal_request(self._report["expectedPid"])
            with self._lock:
                self._report["normalSucceeded"] = succeeded is True
        except BaseException as error:
            with self._lock:
                self._report["normalError"] = str(error)
        finally:
            with self._lock:
                self._report["normalCompleted"] = True

    def _tick(self):
        with self._lock:
            if self._terminal or self._closed:
                return
            elapsed = self._elapsed()
            if self._observe_exit():
                return
            if self._report["observationError"] is not None:
                self._terminal = True
                return
            if self._host is not None:
                try:
                    host_code = self._host.poll()
                except Exception as error:
                    self._report["hostObservationError"] = str(error)
                    self._stop = True
                else:
                    if (not self._report["resumeAttempted"] and host_code is not None) or \
                            (self._report["resumeAttempted"] and host_code not in (None, 0)):
                        self._stop = True
            if not self._report["resumeAttempted"]:
                if self._stop or elapsed >= self._overall:
                    self._cleanup_never_executed()
                return
            if self._normal_at is None and (self._stop or elapsed >= self._overall):
                self._normal_at = elapsed
                self._report["normalRequested"] = True
                self._report["normalRequestMilliseconds"] = int(elapsed * 1000)
                try:
                    self._normal_worker = threading.Thread(target=self._publish_normal,
                        name="BeamRT normal quit publisher", daemon=True)
                    self._normal_worker.start()
                    self._report["normalQueued"] = True
                except BaseException as error:
                    self._report["normalError"] = str(error)
                    self._report["normalCompleted"] = True
                return
            if self._normal_at is not None and elapsed - self._normal_at >= self._grace:
                if not self._force_authorized:
                    self._report["forceUnauthorizedAfterGrace"] = True
                    self._terminal = True
                elif not self._report["forceAttempted"] and not self._observe_exit():
                    if self._report["observationError"] is not None:
                        self._terminal = True
                        return
                    self._report["forceAttempted"] = True
                    self._report["forceAttemptMilliseconds"] = int(elapsed * 1000)
                    try:
                        self._backend.terminate(self._process)
                        self._report["forceSucceeded"] = True
                        self._observe_exit(int(self._termination_wait * 1000))
                    except (OSError, ValueError) as error:
                        self._report["forceError"] = str(error)
                    self._terminal = True

    def _watch(self):
        recovered = False
        try:
            while True:
                try:
                    self._tick()
                except BaseException as error:
                    # A broken injected clock/policy operation must not silently
                    # abandon a live child. One independent monotonic fallback
                    # preserves elapsed time and starts the complete normal
                    # grace anew if it had not already been requested. A second
                    # failure is reported unknown, never fabricated exit proof.
                    with self._lock:
                        self._report["watcherError"] = str(error)
                        if recovered:
                            self._terminal = True
                            return
                        elapsed = self._report["elapsedMilliseconds"] / 1000
                        self._clock, self._last = time.monotonic, None
                        self._created_at = self._now() - elapsed
                        self._stop = True
                        recovered = True
                    continue
                with self._lock:
                    if self._terminal or self._closed:
                        return
                self._wake.wait(0.01)
                self._wake.clear()
        except BaseException as error:
            with self._lock:
                self._report["watcherError"] = str(error)
                self._terminal = True

    def prepare_host_capabilities(self):
        """Explicit one-shot setup channel, called before the native host exists."""
        with self._lock:
            if self._closed or self._terminal or self._capabilities or self._report["resumeAttempted"]:
                raise RuntimeError("one-shot pre-resume capabilities unavailable")
            duplicates = []
            try:
                self._channel = self._backend.create_channel(bytes(CHANNEL_BYTES))
                mapping, ready, grant, _view = self._channel
                for handle, rights in ((self._process, PROCESS_SETUP_RIGHTS), (self._thread, THREAD_SETUP_RIGHTS),
                                       (mapping, 0x0002 | 0x0004), (ready, 0x0002),
                                       (grant, 0x100000)):
                    duplicates.append(self._backend.duplicate(handle, rights))
                capabilities = HostCapabilities(*duplicates)
                self._expected_channel = channel_image(self._token, self._config_digest,
                    self._report["expectedPid"], self._report["expectedThreadId"], self._creation_tick,
                    int(self._overall * 1000), int(self._grace * 1000), int(self._termination_wait * 1000),
                    self._ipc_count, (duplicates[0], duplicates[1], duplicates[3], duplicates[4]))
                self._backend.write_channel(self._channel[3], self._expected_channel)
                self._capabilities = capabilities
                return capabilities
            except BaseException:
                for handle in reversed(duplicates):
                    self._backend.close(handle)
                self._stop = True
                self._wake.set()
                raise

    def launch_host(self, executable, arguments, stdout, working_directory=None):
        """Create, retain and configure the host; an arbitrary host is not adoptable.

        Only the five reduced setup capabilities are inherited. The target child
        existed suspended, privately owned and watched before this call began.
        """
        executable = _absolute_executable(executable)
        if type(arguments) not in (tuple, list) or any(type(value) is not str or "\0" in value for value in arguments):
            raise ValueError("exact host argument vector required")
        if any(value in ("--outer-owned-channel", "--outer-config-sha256") for value in arguments):
            raise ValueError("caller must not supply an inherited channel override")
        working_directory = _absolute_directory(working_directory or ntpath.dirname(executable))
        with self._lock:
            if self._host_attempted or self._closed or self._terminal or self._report["resumeAttempted"]:
                raise RuntimeError("one-shot host launch unavailable")
            self._host_attempted = True
            caps = self._capabilities or self.prepare_host_capabilities()
            values = list(arguments)
            insertion = values.index("--") if "--" in values else len(values)
            values[insertion:insertion] = ("--outer-owned-channel", str(caps.mapping_handle),
                                          "--outer-config-sha256", self._config_digest)
            startup = subprocess.STARTUPINFO() if os.name == "nt" else type("FixtureStartup", (), {})()
            startup.lpAttributeList = {"handle_list": list(caps.handle_list)}
            # Process creation can be slow; do not hold the policy mutex. The
            # watcher must still expire/clean the suspended child independently.
        try:
            host = self._process_factory((executable, *values), stdout=stdout, stderr=subprocess.STDOUT,
                cwd=working_directory, shell=False, close_fds=True,
                startupinfo=startup, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            with self._lock:
                self._host = host
            return {"created": True}
        except BaseException:
            self.request_stop()
            raise

    def host_poll(self):
        with self._lock:
            if self._host is None:
                raise RuntimeError("owned native host has not been created")
            host = self._host
        return host.poll()

    def _checked_channel(self):
        image = self._backend.read_channel(self._channel[3])
        if type(image) is not bytes or len(image) != CHANNEL_BYTES or image[:128] != self._expected_channel[:128] \
                or image[368:] != bytes(144):
            raise ValueError("host channel immutable identity or reserved bytes changed")
        return image

    def _relay_ipc(self, image):
        if self._host is None or self._host.poll() is not None:
            raise RuntimeError("owned native host unavailable during IPC relay")
        if image[132:144] != self._expected_channel[132:144] or any(image[256:368]):
            raise ValueError("host IPC request has premature results")
        sources = struct.unpack_from("<14Q", image, 144)
        active = sources[:self._ipc_count]
        if any(type(value) is not int or not 1 <= value < 0xFFFFFFFFFFFFFFF0 for value in active) \
                or len(set(active)) != len(active) or any(sources[self._ipc_count:]) \
                or set(active) & set(self._capabilities.handle_list):
            raise ValueError("host IPC request has invalid, repeated or unused source handles")
        result = bytearray(image)
        targets = []
        for source, rights in zip(active, IPC_RIGHTS):
            target = self._backend.relay(self._host._handle, source, self._process, rights)
            if type(target) is not int or not 1 <= target < 0xFFFFFFFFFFFFFFF0 or target in targets:
                raise ValueError("kernel IPC relay returned an invalid child capability")
            targets.append(target)
        struct.pack_into("<14Q", result, 256, *targets, *([0] * (14 - len(targets))))
        struct.pack_into("<I", result, 128, 2)
        self._backend.write_channel(self._channel[3], bytes(result))
        self._backend.grant(self._channel[2])
        return bytes(result)

    def await_setup_and_resume(self, timeout_seconds=10, *, host_alive=None):
        """Validate host readiness then resume only the retained original thread."""
        timeout = _seconds(timeout_seconds, 30, "setup wait")
        if host_alive is not None and not callable(host_alive):
            raise ValueError("host liveness callback refused")
        with self._lock:
            if not self._capabilities or self._host is None or self._report["resumeAttempted"] or self._closed:
                raise RuntimeError("setup capabilities required exactly once")
            deadline = self._now() + timeout
            relay_image = None
        try:
            while True:
                with self._lock:
                    if self._terminal or self._stop or self._observe_exit():
                        raise RuntimeError("owned child stopped before ready")
                    if self._report["observationError"] is not None:
                        raise RuntimeError("retained-child exit state unavailable before ready")
                    if self._now() >= deadline:
                        raise TimeoutError("native host setup-ready timeout")
                    if self._backend.ready(self._channel[1]):
                        image = self._checked_channel()
                        state = struct.unpack_from("<I", image, 128)[0]
                        if state == 1 and relay_image is None:
                            relay_image = self._relay_ipc(image)
                            continue
                        expected = bytearray(relay_image or b"")
                        if not expected:
                            raise ValueError("host skipped the IPC relay phase")
                        struct.pack_into("<I", expected, 128, 3)
                        if state != 3 or image != bytes(expected):
                            raise ValueError("host setup-ready channel phase or IPC identity mismatch")
                        if self._backend.identity(self._process, self._thread) != (
                                self._report["expectedPid"], self._report["expectedThreadId"], self._report["expectedPid"]):
                            raise ValueError("retained child identity changed")
                        if self._elapsed() >= self._overall:
                            raise TimeoutError("overall timeout before resume")
                        self._report["setupReady"] = True
                        self._report["resumeAttempted"] = True
                        previous = self._backend.resume(self._thread)
                        self._report["resumed"] = True
                        if previous != 1:
                            raise RuntimeError("unexpected previous suspend count; application may have executed")
                        struct.pack_into("<II", expected, 128, 4, previous)
                        self._backend.write_channel(self._channel[3], bytes(expected))
                        self._backend.grant(self._channel[2])
                        self._report["resumeGranted"] = True
                        return self.report()
                if self.host_poll() is not None or (host_alive is not None and host_alive() is not True):
                    raise RuntimeError("native host exited before setup-ready")
                self._sleep(0.01)
        except BaseException:
            self.request_stop()
            raise

    def request_stop(self):
        with self._lock:
            self._stop = True
            self._wake.set()

    def report(self):
        with self._lock:
            if not self._closed:
                self._observe_exit()
            return dict(self._report)

    def finish(self):
        """Bounded exact-child cleanup; never waits on or terminates the host."""
        self.request_stop()
        if self._watcher is not None and self._watcher.ident is not None:
            self._watcher.join(self._grace + self._termination_wait + 1)
        elif self._watcher is None:
            # Deterministic test seam only; real creation always starts watcher.
            deadline = self._now() + self._grace + self._termination_wait + 1
            while not self._terminal and self._now() < deadline:
                self._tick()
                if not self._terminal:
                    self._sleep(0.01)
        return self.report()

    def _close_handles(self):
        if self._channel:
            self._backend.unmap(self._channel[3])
            for handle in self._channel[:3]:
                self._backend.close(handle)
            self._channel = None
        if self._capabilities:
            for handle in self._capabilities.handle_list:
                self._backend.close(handle)
            self._capabilities = None
        for name in ("_thread", "_process"):
            handle = getattr(self, name)
            if handle:
                self._backend.close(handle)
                setattr(self, name, None)

    def close(self):
        """Finish first. Refuse to discard live capability while watcher runs."""
        if self._closed:
            return self.report()
        report = self.finish()
        with self._lock:
            if not report["processExitVerified"]:
                raise RuntimeError("exact child exit unconfirmed; private capabilities remain retained")
            if self._watcher is not None and self._watcher.is_alive():
                raise RuntimeError("outer watcher remains active; retained child capability not closed")
            if self._normal_worker is not None and not self._report["normalCompleted"]:
                raise RuntimeError("normal publisher remains active; lifetime must remain protected")
            self._close_handles()
            self._closed = True
        return report
