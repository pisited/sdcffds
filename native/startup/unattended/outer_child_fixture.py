"""Review-first exact-child/host fixtures. Never selects or launches BeamNG.

Execution requires a digest from this same review, fixed disposable sibling
filenames, a fresh short validation output directory, and an explicit test flag.
The outer owner creates each suspended child before its native host exists.
No host kill, process lookup, job/tree cleanup, deployment, or retry is present.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import time
import types


TOKEN = "0123456789abcdef0123456789abcdef"
PROFILE = "outer-owned-fixed-disposable-v1"
FIXED_ARTIFACTS = {
    "host": "beamrt_startup_host.exe",
    "faultHost": "beamrt_startup_fault_host.exe",
    "child": "beamrt_startup_fixture.exe",
    "dll": "beamrt_startup_bootstrap.dll",
}
FIXED_SHA256 = {
    "host": "57c8500009032ad92bc6696e0409cd44ee44abf54737af946d23431260936f60",
    "faultHost": "4d368068f1a5d02ae85b8e31bbc9dc63a88b94582cded4308a5ee3aabe7f8890",
    "child": "f10a1a33a07e657ec8414b5b0a9234a1e778a4b96d4ed95feeae51da0fb07e81",
    "dll": "e781e0819a3eea0f6687de45ce03e463ecb8d837c3a6b5f4436350e3ba9cff38",
}
CASE_DEFINITIONS = (
    ("normal", "cooperative", None, True, False),
    ("crash-pre", "cooperative", "crash-before-insert", False, False),
    ("crash-co", "cooperative", "crash-after-resume", True, False),
    ("crash-ig", "ignore", "crash-after-resume", True, True),
    ("hang-pre", "cooperative", "hang-before-insert", False, False),
    ("hang-co", "cooperative", "hang-after-resume", True, False),
    ("hang-ig", "ignore", "hang-after-resume", True, True),
)


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("ascii")


def _digest(path):
    attributes = path.lstat()
    if not stat.S_ISREG(attributes.st_mode) or getattr(attributes, "st_file_attributes", 0) & 0x400:
        raise ValueError("fixed fixture source/artifact is not a physical regular file")
    result, consumed = hashlib.sha256(), 0
    with path.open("rb") as stream:
        while True:
            image = stream.read(1024 * 1024)
            if not image:
                return result.hexdigest()
            consumed += len(image)
            if consumed > 64 * 1024 * 1024:
                raise ValueError("fixed fixture input exceeded 64 MiB budget")
            result.update(image)


def _load(path, image, expected):
    if hashlib.sha256(image).hexdigest() != expected:
        raise ValueError("frozen fixture helper source changed")
    name = "beamrt_outer_fixture_" + path.stem + "_" + expected[:16]
    module = types.ModuleType(name)
    module.__file__ = str(path)
    sys.modules[name] = module
    try:
        exec(compile(image, str(path), "exec", dont_inherit=True), module.__dict__)
    except BaseException:
        sys.modules.pop(name, None)
        raise
    return module


def _new_json(path, value):
    # Identity key insertion order matters to the deliberately tiny C++ child.
    image = json.dumps(value, separators=(",", ":"), allow_nan=False).encode("ascii") + b"\n"
    with path.open("xb") as stream:
        stream.write(image)
        stream.flush()
        os.fsync(stream.fileno())


def review(artifacts, output):
    source = Path(__file__).absolute()
    workspace = source.parents[3]
    validation = workspace / ".beamrt-validation"
    artifacts, output = Path(artifacts).absolute(), Path(output).absolute()
    if os.name != "nt":
        raise OSError("fixed exact-child fixtures require Windows")
    if artifacts.name != "native-b2" \
            or artifacts.parent.parent != validation or not re.fullmatch(r"outer-child-[0-9a-f]{32}", artifacts.parent.name):
        raise ValueError("fixed new outer-child build directory required")
    if output.parent != validation or not re.fullmatch(r"oc-[0-9a-f]{12,32}", output.name):
        raise ValueError("fresh short oc-hex output directly inside validation required")
    if output.exists() or output.is_symlink():
        raise FileExistsError("fixture output is one shot and already exists")
    files = {role: artifacts / leaf for role, leaf in FIXED_ARTIFACTS.items()}
    helpers = {leaf: source.parent / leaf for leaf in
               ("outer_child_owner.py", "protected_inputs.py", "outer_child_fixture.py")}
    manifest = {str(path): _digest(path) for path in (*files.values(), *helpers.values())}
    if any(manifest[str(files[role])] != expected for role, expected in FIXED_SHA256.items()):
        raise ValueError("fixed disposable build artifact pin differs from the reviewed binary")
    plan = {"profile": PROFILE, "artifacts": str(artifacts), "output": str(output),
            "manifest": manifest, "cases": [value[0] for value in CASE_DEFINITIONS],
            "overallSeconds": 2, "normalGraceSeconds": 1,
            "terminationWaitMilliseconds": 5000, "gameSelected": False,
            "hostTerminationAvailable": False, "processLookupAvailable": False}
    plan["reviewSHA256"] = hashlib.sha256(_canonical(plan)).hexdigest()
    return plan, files, helpers


def _host_arguments(files, directory, child_args, manifest):
    return ("--launch-reviewed", "--target", str(files["child"]), "--dll", str(files["dll"]),
        "--workdir", str(directory), "--expected-target-sha256", manifest[str(files["child"])],
        "--expected-dll-sha256", manifest[str(files["dll"])],
        "--acknowledge-native-insertion", "startup-observation-only",
        "--owned-run-directory", str(directory), "--owned-run-token", TOKEN,
        "--owned-overall-seconds", "2", "--owned-normal-grace-seconds", "1",
        "--acknowledge-owned-force-close", "exact-created-child-after-normal-quit", "--", *child_args)


def _retain_until_finished(owner, host_created, directory, result, *, diagnostic_after=10,
                           clock=time.monotonic, sleep=time.sleep):
    """Retain exact capabilities and caller-held inputs through unknown liveness.

    The threshold is diagnostic only, not a resource-release deadline. This path
    never creates, resumes, terminates or reopens a process. Recovery observes
    the same retained handles. Outer-process/OS failure remains outside scope.
    """
    try:
        started = clock()
    except Exception as error:
        result["retentionClockError"] = str(error)
        clock, started = time.monotonic, time.monotonic()
    last_progress, diagnostic_written = 0, False

    def progress(message):
        try:
            print(message, flush=True)
        except Exception as error:
            result["retentionProgressError"] = str(error)
    while True:
        child, host_code = None, None
        try:
            child = owner.report()
            result["child"] = child
        except Exception as error:
            result["retentionChildObservationError"] = str(error)
        try:
            host_code = owner.host_poll() if host_created else None
            result["hostExitVerified"] = host_created and host_code is not None
            result["hostExitCode"] = host_code
            result["hostAliveAtIndependentChildExit"] = result.get("hostAliveAtIndependentChildExit") or \
                bool(child and child["processExitVerified"] and host_created and host_code is None)
        except Exception as error:
            result["retentionHostObservationError"] = str(error)
            result["hostExitVerified"] = False
        publisher_done = bool(child and (not child["normalRequested"] or child["normalCompleted"]))
        if child and child["processExitVerified"] and publisher_done and (not host_created or result["hostExitVerified"]):
            try:
                result["finalChild"] = owner.close()
            except RuntimeError as error:
                result["retentionCloseError"] = str(error)
            else:
                return
        try:
            elapsed = clock() - started
        except Exception as error:
            result["retentionClockError"] = str(error)
            elapsed = 0
        if elapsed >= diagnostic_after and not diagnostic_written:
            diagnostic_written = True
            result["retentionRequired"] = True
            try:
                _new_json(directory / "retention-diagnostic.json", result)
            except Exception as error:
                result["retentionDiagnosticError"] = str(error)
            progress("Exact child or native host exit remains unconfirmed; retaining the same capabilities and input locks.")
            last_progress = elapsed
        elif diagnostic_written and elapsed - last_progress >= 30:
            progress("Still retaining the same exact child, host and protected inputs; read-only exit observation continues.")
            last_progress = elapsed
        try:
            sleep(0.05)
        except Exception as error:
            result["retentionSleepError"] = str(error)
            time.sleep(0.05)


def _run_case(owner_module, files, directory, definition, manifest, review_digest):
    name, mode, fault, expect_resume, expect_force = definition
    directory.mkdir()
    args = (() if fault is None else ("--fixture-host-fault", fault)) + (
        "--owned-fixture-mode", mode, "--owned-fixture-run-dir", str(directory),
        "--owned-fixture-token", TOKEN, "--owned-fixture-module", files["dll"].name,
        "--owned-fixture-report", str(directory / "entered.json"))
    host = files["host" if fault is None else "faultHost"]
    owner, host_created = None, False
    result = {"case": name, "fault": fault, "mode": mode, "status": "failed",
              "gameSelected": False, "hostTerminationAttempted": False,
              "setupError": None, "hostAliveAtIndependentChildExit": None}

    def request_normal(expected_pid):
        _new_json(directory / "owner-stop.json", {"token": TOKEN, "expectedPid": expected_pid,
                                                  "kind": "normal_quit_requested"})
        return True

    try:
        try:
            owner = owner_module.OuterChildOwner.create(str(files["child"]), args, str(directory), token=TOKEN,
                config_digest=review_digest, expected_ipc_count=1, overall_seconds=2,
                normal_grace_seconds=1, force_close_authorized=True, normal_request=request_normal)
        except owner_module.OwnerCreationError as error:
            owner = error.owner
            raise
        with (directory / "host.log").open("xb") as log:
            owner.launch_host(str(host), _host_arguments(files, directory, args, manifest), log)
            host_created = True
            try:
                owner.await_setup_and_resume(timeout_seconds=8)
            except (OSError, ValueError, RuntimeError, TimeoutError) as error:
                result["setupError"] = str(error)
            if fault is None:
                # The harmless child must execute and validate the injected
                # presence-only startup query before requesting ordinary quit.
                until = time.monotonic() + 1
                while not (directory / "entered.json").exists() and time.monotonic() < until:
                    time.sleep(0.01)
                owner.request_stop()
            elif fault.startswith("hang-"):
                # Let the original two-second owner deadline, not a synthetic
                # harness stop call, prove host-independent policy servicing.
                until = time.monotonic() + 5
                while not owner.report()["processExitVerified"] and time.monotonic() < until:
                    time.sleep(0.01)
    except Exception as error:
        result["failure"] = str(error)
    finally:
        if owner is not None:
            try:
                result["child"] = owner.finish()
            except Exception as error:
                result["cleanupError"] = str(error)
            _retain_until_finished(owner, host_created, directory, result)
    child = result.get("child")
    entered = (directory / "entered.json").exists()
    result["childEntryObserved"] = entered
    result["normalRequestConsumed"] = (directory / "entered.json.normal").exists()
    good = child is not None and "failure" not in result and "cleanupError" not in result and \
        child["processExitVerified"] and child["observationError"] is None and child["watcherError"] is None and \
        child["resumeAttempted"] == expect_resume and child["resumed"] == expect_resume and \
        child["forceAttempted"] == expect_force and entered == expect_resume and result["hostExitVerified"]
    if good and not expect_resume:
        good = child["neverExecutedCleanupAttempted"] and child["neverExecutedCleanupSucceeded"] and \
            not child["normalRequested"] and child["exitCode"] == owner_module.FORCED_EXIT_CODE
    elif good:
        good = child["resumeGranted"] and child["normalRequested"] and child["normalQueued"] and \
            child["normalCompleted"] and child["normalSucceeded"] and not child["neverExecutedCleanupAttempted"]
        if expect_force:
            good = good and child["forceSucceeded"] and child["exitCode"] == owner_module.FORCED_EXIT_CODE and \
                child["forceAttemptMilliseconds"] >= child["normalRequestMilliseconds"] + 1000
        else:
            good = good and child["exitCode"] == 0 and result["normalRequestConsumed"]
    if good and fault is not None and fault.startswith("crash-"):
        good = result["hostExitCode"] == 77
    if good and fault is not None and fault.startswith("hang-"):
        good = result["hostAliveAtIndependentChildExit"] and child["elapsedMilliseconds"] >= 2000
        if expect_resume:
            good = good and child["normalRequestMilliseconds"] >= 2000
    if good and fault is None:
        good = result["hostExitCode"] == 0 and result["setupError"] is None
    result["status"] = "pass" if good else "failed"
    _new_json(directory / "case-result.json", result)
    return result


def execute(plan, files, helpers, expected_digest):
    if expected_digest != plan["reviewSHA256"]:
        raise ValueError("explicit unchanged review digest required before fixture execution")
    source = helpers["protected_inputs.py"]
    protection_module = _load(source, source.read_bytes(), plan["manifest"][str(source)])
    output = Path(plan["output"])
    output.mkdir()  # Exact fresh directory only; there is no recursive deletion.
    protection = protection_module.ProtectedInputs(plan["manifest"], str(output))
    results = []
    try:
        protection.open()
        protection.claim_attempt(TOKEN, expected_digest)
        source = helpers["outer_child_owner.py"]
        owner_module = _load(source, protection.read_bytes(str(source)), plan["manifest"][str(source)])
        _new_json(output / "review.json", plan)
        for definition in CASE_DEFINITIONS:
            result = _run_case(owner_module, files, output / definition[0], definition,
                               plan["manifest"], expected_digest)
            results.append(result)
            print(result["status"].upper() + " outer-child " + definition[0], flush=True)
            if result["status"] != "pass":
                break
        aggregate = {"profile": PROFILE, "cases": len(results),
                     "passed": sum(value["status"] == "pass" for value in results),
                     "allPassed": len(results) == len(CASE_DEFINITIONS) and all(value["status"] == "pass" for value in results),
                     "gameSelected": False, "hostTerminationAttempted": False,
                     "results": results}
        _new_json(output / "fixture-result.json", aggregate)
        return aggregate
    finally:
        protection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--run-tests", action="store_true")
    parser.add_argument("--expected-review-sha256")
    args = parser.parse_args()
    try:
        plan, files, helpers = review(args.artifacts, args.output)
        if not args.run_tests:
            if args.expected_review_sha256 is not None:
                raise ValueError("execution digest is unavailable in review-only mode")
            print(json.dumps(plan, indent=2))
            return 0
        result = execute(plan, files, helpers, args.expected_review_sha256)
        print(json.dumps({key: value for key, value in result.items() if key != "results"}, indent=2))
        return 0 if result["allPassed"] else 2
    except (OSError, ValueError, RuntimeError, TimeoutError) as error:
        print("Outer-child fixture refused: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
