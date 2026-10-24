"""Deterministic exact-child owner contracts; no game or native process starts."""
import importlib.util
from pathlib import Path
import struct
import sys
import threading
import time
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[2] / "native/startup/unattended/outer_child_owner.py"
TOKEN = "0123456789abcdef0123456789abcdef"
DIGEST = "a" * 64


def load_module():
    spec = importlib.util.spec_from_file_location("beamrt_outer_child_contract", SOURCE)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class Clock:
    def __init__(self):
        self.value = 100.0

    def now(self):
        return self.value

    def sleep(self, value):
        self.value += value


class FakeHost:
    _handle = 91

    def __init__(self):
        self.code = None

    def poll(self):
        return self.code


class Backend:
    def __init__(self):
        self.events = []
        self.code = None
        self.suspend_count = 1
        self.identity_value = (24680, 13579, 24680)
        self.image = bytes(512)
        self.signalled = False
        self.next_handle = 100
        self.sources = (500,)
        self.on_initial_request = None
        self.on_setup_ready = None
        self.terminate_exits = True
        self.error = {}

    def _failure(self, name):
        if name in self.error:
            raise self.error[name]

    def tick_ms(self):
        return 123456789

    def create_suspended(self, executable, arguments, directory):
        self._failure("create")
        self.events.append(("create", executable, arguments, directory))
        return 11, 12, 24680, 13579

    def identity(self, process, thread):
        self.events.append(("identity", process, thread))
        return self.identity_value

    def observe_exit(self, process, timeout_ms=0):
        self._failure("observe")
        self.events.append(("observe", process, timeout_ms))
        return self.code

    def close(self, handle):
        self.events.append(("close", handle))

    def terminate(self, process):
        self._failure("terminate")
        self.events.append(("terminate", process))
        if self.terminate_exits:
            self.code = 0x42525446

    def resume(self, thread):
        self.events.append(("resume", thread))
        self._failure("resume")
        return self.suspend_count

    def create_channel(self, image):
        self._failure("channel")
        self.image = image
        self.events.append(("channel",))
        return 21, 22, 23, 24

    def duplicate(self, handle, rights):
        self._failure("duplicate")
        self.next_handle += 1
        self.events.append(("duplicate", handle, rights, self.next_handle))
        return self.next_handle

    def relay(self, host_process, source, child_process, rights):
        self._failure("relay")
        self.events.append(("relay", host_process, source, child_process, rights))
        return 1000 + source

    def read_channel(self, view):
        self._failure("read_channel")
        return self.image

    def write_channel(self, view, image):
        self._failure("write_channel")
        self.image = image
        self.events.append(("write", struct.unpack_from("<I", image, 128)[0]))

    def ready(self, event):
        result, self.signalled = self.signalled, False
        return result

    def grant(self, event):
        self.events.append(("grant", struct.unpack_from("<I", self.image, 128)[0]))
        self._failure("grant")
        if struct.unpack_from("<I", self.image, 128)[0] == 2:
            image = bytearray(self.image)
            struct.pack_into("<I", image, 128, 3)
            if self.on_setup_ready:
                self.on_setup_ready(image)
            self.image, self.signalled = bytes(image), True

    def request(self):
        image = bytearray(self.image)
        struct.pack_into("<I", image, 128, 1)
        struct.pack_into("<14Q", image, 144, *self.sources, *([0] * (14 - len(self.sources))))
        if self.on_initial_request:
            self.on_initial_request(image)
        self.image, self.signalled = bytes(image), True

    def unmap(self, view):
        self.events.append(("unmap", view))


class OuterChildOwnerContracts(unittest.TestCase):
    def setUp(self):
        self.module, self.clock, self.backend = load_module(), Clock(), Backend()
        self.host, self.launches, self.normal_calls = FakeHost(), [], []
        self.owners = []

    def tearDown(self):
        for owner in self.owners:
            owner.close()

    def create(self, **changes):
        values = dict(token=TOKEN, config_digest=DIGEST, expected_ipc_count=1,
                      overall_seconds=20, normal_grace_seconds=1,
                      force_close_authorized=True, normal_request=self.normal,
                      _backend=self.backend, _clock=self.clock.now,
                      _sleep=self.clock.sleep, _start_watcher=False,
                      _process_factory=self.factory)
        values.update(changes)
        owner = self.module.OuterChildOwner.create("C:/fixed/child.exe", ("--fixture",),
                                                  "C:/fixed", **values)
        self.owners.append(owner)
        return owner

    def factory(self, arguments, **options):
        self.launches.append((arguments, options))
        self.backend.request()
        return self.host

    def normal(self, process_id):
        self.normal_calls.append(process_id)
        return True

    def start(self, **changes):
        owner = self.create(**changes)
        owner.prepare_host_capabilities()
        owner.launch_host("C:/fixed/host.exe", ("--launch-reviewed", "--", "childarg"), None)
        owner.await_setup_and_resume()
        return owner

    def join_normal(self, owner):
        if owner._normal_worker:
            owner._normal_worker.join(1)

    def test_import_and_constructor_are_inert(self):
        self.assertEqual(self.backend.events, [])
        with self.assertRaises(TypeError):
            self.module.OuterChildOwner()

    def test_validation_precedes_creation(self):
        for changes in ({"token": "A" * 32}, {"config_digest": "A" * 64},
                        {"expected_ipc_count": 2}, {"expected_ipc_count": True},
                        {"overall_seconds": 0}, {"overall_seconds": 481},
                        {"overall_seconds": 0.00001},
                        {"normal_grace_seconds": 31}, {"termination_wait_seconds": 1},
                        {"force_close_authorized": 1}, {"normal_request": None}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.create(**changes)
        self.assertEqual(self.backend.events, [])

    def test_only_factory_created_masters_are_used(self):
        owner = self.create()
        self.assertEqual(owner.report()["expectedPid"], 24680)
        self.assertEqual(self.backend.events[0][0], "create")
        self.assertFalse(any(event[0] == "resume" for event in self.backend.events))

    def test_caps_never_include_master_or_control_rights(self):
        owner = self.create()
        caps = owner.prepare_host_capabilities()
        self.assertEqual(len(caps.handle_list), 5)
        self.assertNotIn(11, caps.handle_list)
        self.assertNotIn(12, caps.handle_list)
        duplicates = [event for event in self.backend.events if event[0] == "duplicate"]
        self.assertEqual(duplicates[0][2], self.module.PROCESS_SETUP_RIGHTS)
        self.assertEqual(duplicates[0][2] & (1 | 0x40 | 0x800), 0)
        self.assertEqual(duplicates[1][2], self.module.THREAD_SETUP_RIGHTS)
        self.assertEqual(duplicates[1][2] & (1 | 2), 0)
        self.assertEqual(duplicates[3][2], 2)
        self.assertEqual(duplicates[4][2], 0x100000)

    def test_host_has_exact_explicit_inheritance_and_flags_before_separator(self):
        owner = self.start()
        arguments, options = self.launches[0]
        separator = arguments.index("--")
        self.assertLess(arguments.index("--outer-owned-channel"), separator)
        self.assertLess(arguments.index("--outer-config-sha256"), separator)
        self.assertEqual(arguments[arguments.index("--outer-config-sha256") + 1], DIGEST)
        self.assertEqual(options["startupinfo"].lpAttributeList["handle_list"], list(owner._capabilities.handle_list))
        self.assertTrue(options["close_fds"])
        self.assertFalse(options["shell"])
        self.assertEqual(arguments[-1], "childarg")

    def test_initial_channel_exact_shared_contract(self):
        owner = self.create()
        caps = owner.prepare_host_capabilities()
        image = self.backend.image
        self.assertEqual(len(image), 512)
        self.assertEqual(image[:8], b"BRTEXT1\0")
        self.assertEqual(struct.unpack_from("<II", image, 8), (512, 1))
        self.assertEqual(image[16:32], bytes.fromhex(TOKEN))
        self.assertEqual(image[32:64], bytes.fromhex(DIGEST))
        self.assertEqual(struct.unpack_from("<IIQIIII", image, 64), (24680, 13579, 123456789, 20000, 1000, 5000, 1))
        self.assertEqual(struct.unpack_from("<4Q", image, 96), (caps.process_handle, caps.thread_handle, caps.ready_event, caps.grant_event))
        self.assertEqual(struct.unpack_from("<4I", image, 128), (0, 0xFFFFFFFF, 0xFFFFFFFF, 0))
        self.assertEqual(image[144:], bytes(368))

    def test_relay_then_setup_then_resume_then_grant(self):
        owner = self.start()
        events = self.backend.events
        relay = next(i for i, value in enumerate(events) if value[0] == "relay")
        resume = next(i for i, value in enumerate(events) if value[0] == "resume")
        grant = next(i for i, value in enumerate(events) if value == ("grant", 4))
        self.assertLess(relay, resume)
        self.assertLess(resume, grant)
        self.assertEqual(events[relay], ("relay", self.host._handle, 500, 11, 2))
        self.assertTrue(owner.report()["resumeGranted"])
        self.assertEqual(struct.unpack_from("<II", self.backend.image, 128), (4, 1))

    def test_all_known_ipc_profiles_use_exact_rights_and_zero_tail(self):
        for count in sorted(self.module.IPC_COUNTS):
            self.backend = Backend()
            self.backend.sources = tuple(range(500, 500 + count))
            owner = self.start(expected_ipc_count=count)
            relays = [event for event in self.backend.events if event[0] == "relay"]
            self.assertEqual(tuple(event[-1] for event in relays), self.module.IPC_RIGHTS[:count])
            values = struct.unpack_from("<14Q", self.backend.image, 256)
            self.assertTrue(all(values[:count]))
            self.assertFalse(any(values[count:]))
            owner.close()

    def test_source_handles_cannot_be_pseudo_duplicate_or_inherited_caps(self):
        for sources in ((0,), (0xFFFFFFFFFFFFFFFF,), (0xFFFFFFFFFFFFFFFE,), (101,)):
            with self.subTest(sources=sources):
                self.backend = Backend()
                self.backend.sources = sources
                owner = self.create()
                owner.prepare_host_capabilities()
                owner.launch_host("C:/fixed/host.exe", (), None)
                with self.assertRaises(ValueError):
                    owner.await_setup_and_resume()
                self.assertFalse(owner.report()["resumeAttempted"])
                owner.close()
        self.backend = Backend()
        self.backend.sources = (500, 500, 501)
        owner = self.create(expected_ipc_count=3)
        owner.launch_host("C:/fixed/host.exe", (), None)
        with self.assertRaises(ValueError):
            owner.await_setup_and_resume()

    def test_every_immutable_region_and_reserved_tail_fail_closed(self):
        for offset in (0, 8, 12, 16, 32, 64, 68, 72, 80, 84, 88, 92, 96, 104, 112, 120, 368, 511):
            with self.subTest(offset=offset):
                self.backend = Backend()
                self.backend.on_initial_request = lambda image, offset=offset: image.__setitem__(offset, image[offset] ^ 1)
                owner = self.create()
                owner.launch_host("C:/fixed/host.exe", (), None)
                with self.assertRaises(ValueError):
                    owner.await_setup_and_resume()
                self.assertFalse(owner.report()["resumeAttempted"])
                owner.close()

    def test_request_cannot_include_unused_or_premature_results(self):
        for offset in (132, 136, 140, 152, 256, 367):
            with self.subTest(offset=offset):
                self.backend = Backend()
                self.backend.on_initial_request = lambda image, offset=offset: image.__setitem__(offset, image[offset] ^ 1)
                owner = self.create()
                owner.launch_host("C:/fixed/host.exe", (), None)
                with self.assertRaises(ValueError):
                    owner.await_setup_and_resume()
                owner.close()

    def test_second_phase_cannot_change_sources_targets_or_results(self):
        for offset in (128, 132, 136, 140, 144, 256, 368):
            with self.subTest(offset=offset):
                self.backend = Backend()
                self.backend.on_setup_ready = lambda image, offset=offset: image.__setitem__(offset, image[offset] ^ 1)
                owner = self.create()
                owner.launch_host("C:/fixed/host.exe", (), None)
                with self.assertRaises(ValueError):
                    owner.await_setup_and_resume()
                self.assertFalse(owner.report()["resumeAttempted"])
                owner.close()

    def test_host_cannot_skip_ipc_phase(self):
        self.backend.on_initial_request = lambda image: struct.pack_into("<I", image, 128, 3)
        owner = self.create()
        owner.launch_host("C:/fixed/host.exe", (), None)
        with self.assertRaisesRegex(ValueError, "skipped"):
            owner.await_setup_and_resume()

    def test_normal_attempt_and_full_grace_before_exact_force(self):
        owner = self.start()
        owner.request_stop()
        owner._tick()
        self.join_normal(owner)
        self.assertEqual(self.normal_calls, [24680])
        self.clock.value += 0.99
        owner._tick()
        self.assertFalse(owner.report()["forceAttempted"])
        self.clock.value += 0.02
        owner._tick()
        report = owner.report()
        self.assertTrue(report["forceAttempted"])
        self.assertTrue(report["processExitVerified"])
        self.assertEqual([event for event in self.backend.events if event[0] == "terminate"], [("terminate", 11)])
        self.assertGreaterEqual(report["forceAttemptMilliseconds"] - report["normalRequestMilliseconds"], 1000)

    def test_blocked_normal_publisher_does_not_block_force_policy(self):
        gate, entered = threading.Event(), threading.Event()

        def blocked(_pid):
            entered.set()
            gate.wait(2)
            return True

        owner = self.start(normal_request=blocked)
        try:
            owner.request_stop()
            owner._tick()
            self.assertTrue(entered.wait(1))
            self.clock.value += 1.01
            owner._tick()
            self.assertTrue(owner.report()["forceAttempted"])
            self.assertFalse(owner.report()["normalCompleted"])
        finally:
            gate.set()
            self.join_normal(owner)

    def test_false_or_throwing_normal_still_gets_full_grace(self):
        def throwing(_pid):
            raise OSError("fixture normal publication failure")

        for publisher in (lambda _pid: False, throwing):
            self.backend = Backend()
            owner = self.start(normal_request=publisher)
            owner.request_stop()
            owner._tick()
            self.join_normal(owner)
            self.assertFalse(owner.report()["normalSucceeded"])
            self.clock.value += 0.99
            owner._tick()
            self.assertFalse(owner.report()["forceAttempted"])
            self.clock.value += 0.02
            owner._tick()
            self.assertTrue(owner.report()["forceAttempted"])
            owner.close()

    def test_natural_exit_during_grace_prevents_force(self):
        owner = self.start()
        owner.request_stop()
        owner._tick()
        self.backend.code = 0
        self.clock.value += 2
        owner._tick()
        self.assertTrue(owner.report()["processExitVerified"])
        self.assertFalse(owner.report()["forceAttempted"])

    def test_signalled_exit_259_is_valid_exit_proof(self):
        owner = self.create()
        self.backend.code = 259
        self.assertEqual(owner.report()["exitCode"], 259)
        self.assertTrue(owner.report()["processExitVerified"])
        self.assertFalse(owner.report()["neverExecutedCleanupAttempted"])

    def test_terminate_success_without_signal_is_not_exit_proof(self):
        self.backend.terminate_exits = False
        owner = self.start()
        report = owner.finish()
        self.assertTrue(report["forceSucceeded"])
        self.assertFalse(report["processExitVerified"])
        self.assertIsNone(report["exitCode"])
        with self.assertRaisesRegex(RuntimeError, "capabilities remain retained"):
            owner.close()
        self.assertFalse(any(event == ("close", 11) for event in self.backend.events))
        self.backend.code = 0

    def test_no_force_authority_reports_unknown_after_grace(self):
        owner = self.start(force_close_authorized=False)
        report = owner.finish()
        self.assertTrue(report["forceUnauthorizedAfterGrace"])
        self.assertFalse(report["forceAttempted"])
        self.assertFalse(report["processExitVerified"])
        self.backend.code = 0

    def test_host_crash_before_resume_never_executes_child(self):
        owner = self.create()
        owner.launch_host("C:/fixed/host.exe", (), None)
        self.host.code = 77
        owner._tick()
        report = owner.report()
        self.assertTrue(report["neverExecutedCleanupAttempted"])
        self.assertTrue(report["processExitVerified"])
        self.assertFalse(report["resumeAttempted"])
        self.assertEqual(self.normal_calls, [])

    def test_host_crash_after_resume_requests_normal_then_grace(self):
        owner = self.start()
        self.host.code = 77
        owner._tick()
        self.assertTrue(owner.report()["normalRequested"])
        self.assertFalse(owner.report()["forceAttempted"])
        self.clock.value += 1.01
        owner._tick()
        self.assertTrue(owner.report()["processExitVerified"])

    def test_successful_host_exit_does_not_preempt_lua_ack(self):
        owner = self.start()
        self.host.code = 0
        owner._tick()
        self.assertFalse(owner.report()["normalRequested"])

    def test_host_hang_does_not_reset_overall_deadline(self):
        owner = self.start()
        self.clock.value += 20
        owner._tick()
        self.assertTrue(owner.report()["normalRequested"])
        self.clock.value += 1
        owner._tick()
        self.assertTrue(owner.report()["forceAttempted"])
        self.assertEqual(self.host.code, None)

    def test_suspended_overall_deadline_needs_no_host_export_window(self):
        owner = self.create()
        self.clock.value += 20
        owner._tick()
        report = owner.report()
        self.assertTrue(report["neverExecutedCleanupAttempted"])
        self.assertTrue(report["processExitVerified"])
        self.assertFalse(report["resumeAttempted"])
        self.assertEqual(self.launches, [])

    def test_resume_fail_and_unexpected_count_use_live_conservative_policy(self):
        for error, previous in ((OSError("fixture resume failure"), 1), (None, 0), (None, 2)):
            with self.subTest(previous=previous, error=error):
                self.backend = Backend()
                self.backend.suspend_count = previous
                if error:
                    self.backend.error["resume"] = error
                owner = self.create()
                owner.launch_host("C:/fixed/host.exe", (), None)
                with self.assertRaises((OSError, RuntimeError)):
                    owner.await_setup_and_resume()
                report = owner.finish()
                self.assertTrue(report["resumeAttempted"])
                self.assertFalse(report["neverExecutedCleanupAttempted"])
                self.assertTrue(report["normalRequested"])
                self.assertTrue(report["forceAttempted"])
                owner.close()

    def test_setup_timeout_and_relay_error_never_resume(self):
        for failure in ("timeout", "relay"):
            self.backend = Backend()
            if failure == "relay":
                self.backend.error["relay"] = OSError("fixture relay failure")
            owner = self.create()
            owner.launch_host("C:/fixed/host.exe", (), None)
            if failure == "timeout":
                self.backend.signalled = False
            with self.assertRaises((OSError, TimeoutError)):
                owner.await_setup_and_resume(0.1)
            report = owner.finish()
            self.assertFalse(report["resumeAttempted"])
            self.assertTrue(report["neverExecutedCleanupAttempted"])
            owner.close()

    def test_owner_cannot_be_reused_or_host_identity_overridden(self):
        owner = self.start()
        for operation in (owner.prepare_host_capabilities, owner.await_setup_and_resume,
                          lambda: owner.launch_host("C:/fixed/host.exe", (), None)):
            with self.assertRaises(RuntimeError):
                operation()
        other = self.create()
        for flag in ("--outer-owned-channel", "--outer-config-sha256"):
            with self.assertRaises(ValueError):
                other.launch_host("C:/fixed/host.exe", (flag, "123"), None)

    def test_host_failure_never_uses_host_termination_or_pid_reopen(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertNotIn('"OpenProcess"', source)
        self.assertNotIn("os.kill(", source)
        self.assertNotIn(".kill(", source)
        self.assertNotIn(".terminate(", source.replace("self._backend.terminate(", ""))
        self.assertNotIn("CREATE_BREAKAWAY_FROM_JOB", source)

    def test_exit_query_failure_refuses_resume(self):
        owner = self.create()
        owner.launch_host("C:/fixed/host.exe", (), None)
        self.backend.error["observe"] = OSError("fixture wait failure")
        with self.assertRaisesRegex(RuntimeError, "exit state unavailable"):
            owner.await_setup_and_resume()
        self.assertFalse(owner.report()["resumeAttempted"])
        self.assertFalse(owner.report()["processExitVerified"])
        del self.backend.error["observe"]
        self.backend.code = 0

    def test_observation_error_blocks_force_in_live_and_never_executed_paths(self):
        for resumed in (False, True):
            with self.subTest(resumed=resumed):
                self.backend = Backend()
                owner = self.start() if resumed else self.create()
                self.backend.error["observe"] = OSError("fixture retained-child observation unavailable")
                owner.request_stop()
                owner._tick()
                self.clock.value += 30
                owner._tick()
                report = owner.report()
                self.assertIsNotNone(report["observationError"])
                self.assertFalse(report["processExitVerified"])
                self.assertFalse(report["forceAttempted"])
                self.assertFalse(report["neverExecutedCleanupAttempted"])
                self.assertFalse(any(event[0] == "terminate" for event in self.backend.events))
                del self.backend.error["observe"]
                self.backend.code = 0
                owner.close()

    def test_channel_publication_failure_does_not_double_close_duplicates(self):
        owner = self.create()
        self.backend.error["write_channel"] = OSError("fixture channel write failed")
        with self.assertRaises(OSError):
            owner.prepare_host_capabilities()
        self.assertIsNone(owner._capabilities)
        owner.close()
        duplicates = [event[-1] for event in self.backend.events if event[0] == "duplicate"]
        closed = [event[1] for event in self.backend.events if event[0] == "close"]
        for handle in duplicates:
            self.assertEqual(closed.count(handle), 1)

    def test_repeated_host_poll_error_does_not_abandon_exact_child_cleanup(self):
        owner = self.start()

        def failed_poll():
            raise OSError("fixture host query unavailable")

        self.host.poll = failed_poll
        owner._tick()
        self.clock.value += 1.01
        owner._tick()
        report = owner.report()
        self.assertTrue(report["normalRequested"])
        self.assertTrue(report["forceAttempted"])
        self.assertTrue(report["processExitVerified"])
        self.assertIsNotNone(report["hostObservationError"])

    def test_post_create_failure_carries_retained_actual_child_capability(self):
        self.backend.identity_value = (999, 13579, 999)
        self.backend.error["observe"] = OSError("fixture initial wait unavailable")
        with self.assertRaises(self.module.OwnerCreationError) as caught:
            self.create()
        owner = caught.exception.owner
        self.owners.append(owner)
        self.assertEqual(owner.report()["expectedPid"], 24680)
        self.assertFalse(owner.report()["processExitVerified"])
        self.assertFalse(any(event[0] == "close" for event in self.backend.events))
        with self.assertRaises(RuntimeError):
            owner.close()
        del self.backend.error["observe"]
        self.backend.code = 259
        report = owner.close()
        self.assertTrue(report["processExitVerified"])
        self.assertEqual(report["exitCode"], 259)

    def test_failed_watcher_start_can_recover_retained_exit_without_joining_unstarted_thread(self):
        self.backend.terminate_exits = False
        with patch.object(threading.Thread, "start", side_effect=RuntimeError("fixture thread start failure")):
            with self.assertRaises(self.module.OwnerCreationError) as caught:
                self.create(_start_watcher=True)
        owner = caught.exception.owner
        self.owners.append(owner)
        self.assertIsNone(owner._watcher.ident)
        self.assertFalse(owner.report()["processExitVerified"])
        self.assertTrue(owner.report()["neverExecutedCleanupAttempted"])
        with self.assertRaisesRegex(RuntimeError, "exit unconfirmed"):
            owner.close()
        self.backend.code = 0
        self.assertTrue(owner.close()["processExitVerified"])
        self.assertEqual(len([event for event in self.backend.events if event[0] == "terminate"]), 1)

    def test_real_outer_thread_runs_before_any_native_host(self):
        owner = self.create(_start_watcher=True, _clock=time.monotonic,
                            _sleep=time.sleep, overall_seconds=0.02)
        report = owner.finish()
        self.assertTrue(report["neverExecutedCleanupAttempted"])
        self.assertTrue(report["processExitVerified"])
        self.assertEqual(self.launches, [])

    def test_real_outer_thread_continues_while_normal_publisher_is_blocked(self):
        gate, entered = threading.Event(), threading.Event()

        def blocked(_pid):
            entered.set()
            gate.wait(1)
            return True

        owner = self.start(_start_watcher=True, _clock=time.monotonic,
                           _sleep=time.sleep, normal_grace_seconds=0.02,
                           normal_request=blocked)
        try:
            owner.request_stop()
            self.assertTrue(entered.wait(1))
            report = owner.finish()
            self.assertTrue(report["processExitVerified"])
            self.assertTrue(report["forceAttempted"])
            self.assertFalse(report["normalCompleted"])
            self.assertGreaterEqual(report["forceAttemptMilliseconds"] - report["normalRequestMilliseconds"], 20)
        finally:
            gate.set()
            self.join_normal(owner)


if __name__ == "__main__":
    unittest.main()
