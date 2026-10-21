"""Fixed disposable WARP/CPU receipt rendezvous, never a game launch utility.

Only the exact compiled sibling fixtures below are accepted. This is not the
production outer coordinator and never attaches to, discovers or kills a PID.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import time
import uuid


TOKEN = "0123456789abcdef0123456789abcdef"
PINS = {
    "beamrt_startup_host.exe": "fe36d8067fa1b8bc128a2fc2df880011a1b5a46d9a666d6e1022418d2b7dda55",
    "beamrt_binding_startup_fixture.exe": "99c4e0713a7aa39a98d43ce8930633ef29b76fa7c940eb627aca9292fe1d182e",
    "beamrt_startup_bootstrap.dll": "e781e0819a3eea0f6687de45ce03e463ecb8d837c3a6b5f4436350e3ba9cff38",
    "binding.vs.cso": "5574ee84b01de3c361fd083c3cc918bd893cc0f4a9c862e18d65983ab459811f",
    "binding.ps.cso": "0b41369f3dce102dedb50e049bd08f3dfdd86626995d1609da36543023f7a09f",
}


def load_helper():
    spec = importlib.util.spec_from_file_location("beamrt_fixed_handoff", Path(__file__).with_name("receipt_handoff.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def fixture_arguments(build, directory, *, overall=20, receipt_wait=5):
    """Pure fixed-fixture argv; no reads, writes or process creation."""
    return [str(build / "beamrt_startup_host.exe"), "--launch-reviewed",
        "--target", str(build / "beamrt_binding_startup_fixture.exe"),
        "--dll", str(build / "beamrt_startup_bootstrap.dll"), "--workdir", str(directory),
        "--expected-target-sha256", PINS["beamrt_binding_startup_fixture.exe"],
        "--expected-dll-sha256", PINS["beamrt_startup_bootstrap.dll"],
        "--acknowledge-native-insertion", "startup-observation-only", "--entry-rendezvous", "--observe-device-import",
        "--observe-gi-creation", "--gi-vertex", str(build / "binding.vs.cso"),
        "--expected-gi-vertex-sha256", PINS["binding.vs.cso"], "--gi-pixel", str(build / "binding.ps.cso"),
        "--expected-gi-pixel-sha256", PINS["binding.ps.cso"], "--pipeline-root-out", str(directory / "root.bin"),
        "--observe-gi-bindings", "--bindings-out", str(directory / "recorded-draw.bin"),
        "--observe-gi-resources", "--resource-descriptors-only", "--resource-interned-storage",
        "--owned-run-directory", str(directory), "--owned-run-token", TOKEN,
        "--owned-overall-seconds", str(overall), "--owned-normal-grace-seconds", "1",
        "--acknowledge-owned-force-close", "exact-created-child-after-normal-quit",
        "--owned-receipt-wait-seconds", str(receipt_wait), "--",
        "--device-backend", "warp", "--vs", str(build / "binding.vs.cso"), "--ps", str(build / "binding.ps.cso"),
        "--binding-case", "resource-interned", "--report", str(directory / "fixture-report.bin"),
        "--module", "beamrt_startup_bootstrap.dll", "--hold-ms", "0", "--exit-code", "0", "--",
        "", "space value", "ends\\", 'a\\"b', "\u96ea", "--launch-reviewed"]


def run_case(build, evidence, decoder, name, *, acknowledge=True, corrupt=False, overall=20, receipt_wait=5):
    directory = evidence / name
    directory.mkdir()
    host_args = fixture_arguments(build, directory, overall=overall, receipt_wait=receipt_wait)
    (directory / "command.json").write_text(json.dumps(host_args, ensure_ascii=True), encoding="ascii")
    ack, refusal = None, None
    started = time.monotonic()
    with (directory / "host.log").open("xb") as log:
        # Popen retains this newly created HOST process handle. The host's private
        # master owns its exact child; no child PID is reopened by this fixture.
        process = subprocess.Popen(host_args, stdout=log, stderr=subprocess.STDOUT,
                                   cwd=build, creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            until = time.monotonic() + 12
            while not (directory / "receipt-ready.json").exists():
                if process.poll() is not None:
                    raise AssertionError("fixed host exited before receipt-ready")
                if time.monotonic() >= until:
                    raise TimeoutError("fixed ready deadline expired")
                time.sleep(0.02)
            # This context is from the already-running, fixed hash-pinned native
            # creator, never extracted from the raw draw/resource receipt.
            context = json.loads((directory / "process-context.json").read_text("ascii"))
            if set(context) != {"token", "expectedPid"} or context["token"] != TOKEN:
                raise AssertionError("fixed native owner context mismatched")
            if corrupt:
                record = directory / "recorded-draw.bin"
                image = record.read_bytes()
                record.write_bytes(b"\0" * len(image))
            if acknowledge:
                try:
                    ack = load_helper().wait_and_ack(directory, context["expectedPid"], TOKEN, decoder, timeout_seconds=1)
                except ValueError as error:
                    if not corrupt:
                        raise
                    refusal = str(error)
            code = process.wait(timeout=30)
        finally:
            # Even failed assertions wait on this exact retained host, leaving its
            # creation-origin watcher and child self-deadline operational.
            if process.poll() is None:
                process.wait(timeout=30)
    report = json.loads((directory / "owned-exit.json").read_text("ascii"))
    assert report["processExitVerified"] is True and report["expectedPid"] == context["expectedPid"]
    assert report["forceAttempted"] is False and report["observationError"] == 0
    if acknowledge and not corrupt:
        assert code == 0 and ack is not None and report["exitCode"] == 0
        assert report["normalRequested"] is False and not (directory / "owner-stop.json").exists()
        consumed = json.loads((directory / "fixture-ack-consumed.json").read_text("ascii"))
        assert consumed == {"token": TOKEN, "expectedPid": context["expectedPid"],
                            "kind": "fixture_ack_consumed", "digest": ack["digest"]}
    else:
        assert code == 17 and report["normalRequested"] is True and report["exitCode"] == 98
        assert not (directory / "driver-ack.json").exists()
        assert not (directory / "fixture-ack-consumed.json").exists()
        if corrupt:
            assert refusal is not None
        if name == "overall-still-active":
            assert 2000 <= report["normalRequestMilliseconds"] < 5000
        else:
            assert report["normalRequestMilliseconds"] >= receipt_wait * 1000
    result = {"case": name, "hostExit": code, "childExit": report["exitCode"],
              "expectedPid": context["expectedPid"], "ackPublished": ack is not None,
              "decoderRefusal": refusal, "elapsedSeconds": time.monotonic() - started,
              "normalRequested": report["normalRequested"], "processExitVerified": report["processExitVerified"],
              "forceAttempted": report["forceAttempted"]}
    (directory / "fixture-result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="ascii")
    print("PASS fixed WARP receipt handoff: " + name, flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path)
    parser.add_argument("decoder", type=Path)
    args = parser.parse_args()
    build = args.build.resolve(strict=True)
    root = Path(__file__).resolve().parents[3]
    validation = root / ".beamrt-validation"
    if not build.is_relative_to(validation):
        raise ValueError("fixed disposable artifacts must stay inside project validation directory")
    for leaf, digest in PINS.items():
        if hashlib.sha256((build / leaf).read_bytes()).hexdigest() != digest:
            raise ValueError("fixed fixture pin mismatch: " + leaf)
    decoder = args.decoder.resolve(strict=True)
    if decoder.name != "receipt_decoder.exe" or hashlib.sha256(decoder.read_bytes()).hexdigest() != "0aac455d357fdb8414f95c92cb539f8154136e5b6a48fe49971f7525ef65f804":
        raise ValueError("fixed decoder pin mismatch")
    # Legacy core receipt writers use ordinary Win32 paths. Keep these runtime
    # leaves short; the separately tested owner metadata long-path support does
    # not imply all older core artifact writers were upgraded.
    evidence = validation / ("handoff-" + uuid.uuid4().hex[:16])
    evidence.mkdir()
    print("Fixed disposable handoff evidence: " + str(evidence), flush=True)
    results = [run_case(build, evidence, decoder, "validated-ack"),
               run_case(build, evidence, decoder, "missing-ack", acknowledge=False, receipt_wait=1),
               run_case(build, evidence, decoder, "decoder-refusal", corrupt=True, receipt_wait=1),
               run_case(build, evidence, decoder, "overall-still-active", acknowledge=False, overall=2, receipt_wait=30)]
    (evidence / "results.json").write_text(json.dumps(results, indent=2) + "\n", encoding="ascii")
    print("PASS four exact fixed WARP/CPU handoff cases; no BeamNG launch, resource reuse or native GI.", flush=True)


if __name__ == "__main__":
    main()
