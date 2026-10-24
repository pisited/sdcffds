"""Inert, bounded CPU-receipt rendezvous; no launch, shutdown or ownership API.

The caller supplies an expected PID from its retained exact-child owner. Context
and ready files only join that identity; they cannot independently establish it.
Publication is not proof of engine consumption, process exit or GPU success.
"""
from __future__ import annotations

import importlib.util
import json
import math
import os
from pathlib import Path
import re
import stat
import time


SIZES = (("", 1144), (".resources-start.bin", 392), (".resources.bin", 32768))


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate rendezvous JSON key")
        result[key] = value
    return result


def _finite(value):
    number = float(value)
    if not math.isfinite(number):
        raise ValueError("nonfinite rendezvous JSON")
    return number


def _constant(_value):
    raise ValueError("nonfinite rendezvous JSON")


def _physical(path: Path, directory: bool = False):
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
        raise ValueError("reparse rendezvous path refused")
    if not (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)):
        raise ValueError("unexpected rendezvous path type")


def _read(path: Path):
    _physical(path)
    with path.open("rb") as stream:
        image = stream.read(4097)
    if not image or len(image) > 4096:
        raise ValueError("rendezvous JSON size refused")
    value = json.loads(image.decode("utf-8"), object_pairs_hook=_unique,
                       parse_constant=_constant, parse_float=_finite)
    return image, value


def _exact(value, expected):
    if type(value) is not dict or value.keys() != expected.keys() or any(
            type(value[key]) is not type(item) or value[key] != item
            for key, item in expected.items()):
        raise ValueError("rendezvous identity/schema/configuration refused")


def _fresh(run_dir):
    # started/events are expected here: the engine has already claimed the run.
    for name in ("driver-ack.json", "owner-stop.json", "owned-exit.json"):
        for leaf in (name, name + ".pending"):
            try:
                (run_dir / leaf).lstat()
            except FileNotFoundError:
                continue
            raise FileExistsError("completed/stopped rendezvous refused")


def _publish(decoder, record, expected_pid, token, output):
    # Lazy physical import keeps module import inert. The existing helper owns
    # exact decoder hashing, full native bundle validation and atomic ACK output.
    spec = importlib.util.spec_from_file_location(
        "beamrt_cpu_receipt_ack", Path(__file__).with_name("receipt_ack.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.publish_ack(decoder, record, expected_pid, token, output)


def wait_and_ack(run_dir: Path, expected_pid: int, token: str, decoder: Path, *,
                 timeout_seconds: float, poll_seconds: float = 0.05,
                 clock=time.monotonic, sleep=time.sleep, publisher=None) -> dict:
    """Join an explicit owner context to ready, validate once, publish one ACK.

    Missing ready is polled, not a failed-attempt retry. Readable malformed ready,
    an incomplete ready bundle or decoder refusal consumes this call immediately.
    The <=30 second polling budget excludes the pinned decoder's own <=20 second
    subprocess bound. The independent native overall watchdog remains decisive.
    Files must be serialized/protected by the eventual owning coordinator; these
    read/check operations are not a hostile-filesystem or executable-lock barrier.
    """
    if type(expected_pid) is not int or not 1 <= expected_pid <= 0xFFFFFFFF:
        raise ValueError("explicit retained-child PID required")
    if not isinstance(token, str) or re.fullmatch(r"[0-9a-f]{32}", token) is None:
        raise ValueError("explicit 32-hex token required")
    for value, maximum in ((timeout_seconds, 30), (poll_seconds, 1)):
        if type(value) not in (int, float) or not math.isfinite(value) or not 0 < value <= maximum:
            raise ValueError("bounded finite rendezvous timing required")
    run_dir = Path(run_dir)
    if not run_dir.is_absolute() or ".." in run_dir.parts or (os.name == "nt" and not re.match(r"^[A-Za-z]:[\\/]", str(run_dir))):
        raise ValueError("explicit physical local run directory required")
    for component in reversed((run_dir, *run_dir.parents)):
        _physical(component, directory=True)
    context = {"token": token, "expectedPid": expected_pid}
    approval = {"token": token, "scope": "beamrt-unattended-observation-v1", "allow": True}
    ready = {"token": token, "expectedPid": expected_pid, "kind": "cpu_receipt_ready",
             "resourceABI": 7, "drawABI": 5, "profile": 2, "mode": 1,
             "cbvProbeBytes": 0, "record": "recorded-draw.bin"}
    original = {}
    for leaf, expected in (("process-context.json", context), ("launch-approval.json", approval)):
        image, value = _read(run_dir / leaf)
        _exact(value, expected)
        original[leaf] = image
    last = None

    def now():
        nonlocal last
        current = clock()
        if type(current) not in (int, float) or not math.isfinite(current) or (last is not None and current < last):
            raise ValueError("invalid/regressing rendezvous clock")
        last = current
        return current

    deadline = now() + timeout_seconds
    while True:
        _fresh(run_dir)
        for leaf, image in original.items():
            if _read(run_dir / leaf)[0] != image:
                raise ValueError("owner context changed during rendezvous")
        remaining = deadline - now()
        if remaining <= 0:
            raise TimeoutError("CPU receipt-ready deadline expired")
        try:
            _image, value = _read(run_dir / "receipt-ready.json")
        except FileNotFoundError:
            sleep(min(poll_seconds, remaining))
            continue
        except PermissionError as error:
            if getattr(error, "winerror", None) not in (32, 33):
                raise
            sleep(min(poll_seconds, remaining))
            continue
        _exact(value, ready)
        record = run_dir / "recorded-draw.bin"
        for suffix, size in SIZES:
            path = Path(str(record) + suffix)
            _physical(path)
            with path.open("rb") as stream:
                if len(stream.read(size + 1)) != size:
                    raise ValueError("ready bundle is incomplete or wrong-sized")
        _fresh(run_dir)
        if now() >= deadline:
            raise TimeoutError("CPU receipt validation start deadline expired")
        ack = (publisher or _publish)(Path(decoder), record, expected_pid, token, run_dir / "driver-ack.json")
        expected = {"token": token, "kind": "receipt_validated", "expectedPid": expected_pid,
                    "resourceABI": 7, "profile": 2, "mode": 1, "cbvProbeBytes": 0, "digest": ""}
        if type(ack) is not dict or type(ack.get("digest")) is not str or re.fullmatch(r"[0-9a-f]{64}", ack["digest"]) is None:
            raise ValueError("publisher returned malformed ACK")
        expected["digest"] = ack["digest"]
        _exact(ack, expected)
        return ack
