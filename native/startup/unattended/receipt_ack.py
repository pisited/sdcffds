"""Publish an immutable acknowledgement of one CPU receipt bundle, never a game run.

The future owning coordinator must supply its retained child's expected PID.
This tool does not infer process ownership from a receipt, inspect a process,
launch BeamNG, or certify GPU execution/lighting/normal shutdown.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


DECODER_SHA256 = "0aac455d357fdb8414f95c92cb539f8154136e5b6a48fe49971f7525ef65f804"
BUNDLE = (("", 1144), (".resources-start.bin", 392), (".resources.bin", 32768))


def _bundle(record: Path) -> tuple[bytes, ...]:
    images = []
    for suffix, size in BUNDLE:
        with Path(str(record) + suffix).open("rb") as stream:
            image = stream.read(size + 1)
        if len(image) != size:
            raise ValueError("missing, incomplete or wrong-sized receipt bundle")
        images.append(image)
    return tuple(images)


def _nonfinite(value: str):
    raise ValueError("nonfinite decoder JSON")


def _finite_float(value: str):
    number = float(value)
    if not math.isfinite(number):
        raise ValueError("nonfinite decoder JSON")
    return number


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate decoder JSON key")
        result[key] = value
    return result


def publish_ack(decoder: Path, record: Path, expected_pid: int, token: str, output: Path) -> dict:
    if type(expected_pid) is not int or not 1 <= expected_pid <= 0xFFFFFFFF:
        raise ValueError("explicit owned expected PID required")
    if not isinstance(token, str) or not re.fullmatch(r"[0-9a-f]{32}", token):
        raise ValueError("explicit lowercase 32-hex run token required")
    decoder = Path(decoder).resolve(strict=True)
    record = Path(record).resolve(strict=True)
    output = Path(output).absolute()
    if output.name != "driver-ack.json" or output.parent.resolve(strict=True) != record.parent:
        raise ValueError("acknowledgement must be driver-ack.json beside the owned receipt")
    if output.exists() or output.is_symlink():
        raise FileExistsError("acknowledgement already exists; no overwrite or retry")
    if decoder.name.lower() != "receipt_decoder.exe" or hashlib.sha256(decoder.read_bytes()).hexdigest() != DECODER_SHA256:
        raise ValueError("decoder is not the frozen reviewed ABI7 binary")
    before = _bundle(record)
    completed = subprocess.run(
        (str(decoder), str(record), str(expected_pid), "1", "2"),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20, check=False,
    )
    if completed.returncode != 0:
        raise ValueError("full native receipt validator refused the bundle")
    if len(completed.stdout) > 262144:
        raise ValueError("decoder JSON exceeded output budget")
    decoded = json.loads(completed.stdout.decode("utf-8"), parse_constant=_nonfinite, parse_float=_finite_float,
                         object_pairs_hook=_unique_object)
    if type(decoded) is not dict:
        raise ValueError("decoder JSON is not an object")
    expected = {"processId": expected_pid, "mode": 1, "profile": 2,
                "resourceTransportABI": 7, "drawABI": 5, "cbvProbeBytes": 0}
    if any(type(decoded.get(key)) is not int or decoded[key] != value for key, value in expected.items()) \
            or decoded.get("allProofFlagsZero") is not True:
        raise ValueError("decoded identity/configuration/proof flags do not match the owned run")
    if _bundle(record) != before:
        raise ValueError("receipt bytes changed during validation")
    if hashlib.sha256(decoder.read_bytes()).hexdigest() != DECODER_SHA256:
        raise ValueError("frozen decoder changed during validation")
    digest = hashlib.sha256(b"BeamRT CPU receipt bundle ABI7\0")
    for (suffix, _), image in zip(BUNDLE, before):
        digest.update(suffix.encode("ascii") + b"\0")
        digest.update(len(image).to_bytes(8, "little"))
        digest.update(image)
    ack = {"token": token, "kind": "receipt_validated", "expectedPid": expected_pid,
           "resourceABI": 7, "profile": 2, "mode": 1, "cbvProbeBytes": 0,
           "digest": digest.hexdigest()}
    encoded = (json.dumps(ack, separators=(",", ":")) + "\n").encode("ascii")
    # Same-directory hard-link publication is atomic and refuses an existing name.
    # This is not a power-loss durability or future resource-lifetime guarantee.
    descriptor, temporary = tempfile.mkstemp(prefix=".beamrt-ack-", suffix=".tmp", dir=output.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, output)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
    return ack


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--decoder", type=Path, required=True)
    parser.add_argument("--record", type=Path, required=True)
    parser.add_argument("--expected-pid", type=int, required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        ack = publish_ack(args.decoder, args.record, args.expected_pid, args.token, args.output)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("Acknowledgement refused: " + str(error), file=sys.stderr)
        return 1
    print(json.dumps(ack, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
