"""Review-first startup wiring; execution is restricted to fixed WARP fixtures.

Game plans cannot be executed here. An independent exact-child capability for a
crashed/hung native host is still missing. No PID lookup, host termination, job
tree termination, persistent installation or implicit retry is implemented.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import ntpath
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
import types


FIXTURE_PROFILE = "fixed-warp-receipt-v1"
GAME_PROFILE = "beamng-observation-review-v1"
TOKEN = "0123456789abcdef0123456789abcdef"
HELPERS = frozenset(("protected_runner.py", "protected_inputs.py", "startup_plan.py",
                     "receipt_handoff.py", "receipt_ack.py", "receipt_handoff_fixture.py"))
FIXTURE_PINS = {
    "host": ("beamrt_startup_host.exe", "fe36d8067fa1b8bc128a2fc2df880011a1b5a46d9a666d6e1022418d2b7dda55"),
    "target": ("beamrt_binding_startup_fixture.exe", "99c4e0713a7aa39a98d43ce8930633ef29b76fa7c940eb627aca9292fe1d182e"),
    "dll": ("beamrt_startup_bootstrap.dll", "e781e0819a3eea0f6687de45ce03e463ecb8d837c3a6b5f4436350e3ba9cff38"),
    "vertex": ("binding.vs.cso", "5574ee84b01de3c361fd083c3cc918bd893cc0f4a9c862e18d65983ab459811f"),
    "pixel": ("binding.ps.cso", "0b41369f3dce102dedb50e049bd08f3dfdd86626995d1609da36543023f7a09f"),
    "decoder": ("receipt_decoder.exe", "0aac455d357fdb8414f95c92cb539f8154136e5b6a48fe49971f7525ef65f804"),
}
HEX64 = re.compile(r"[0-9a-f]{64}")
OWNER_BOOL_FIELDS = frozenset(("processExitVerified", "resumeAttempted", "resumed", "normalRequested",
    "normalCallReturned", "normalCallSucceeded", "normalCallThrew", "forceAttempted", "forceCallSucceeded",
    "neverExecutedCleanupAttempted", "neverExecutedCleanupCallSucceeded", "beforeResumeTimedOut",
    "stopQueued", "stopCompleted", "stopSucceeded"))
OWNER_NUMBER_FIELDS = frozenset(("expectedPid", "coreResult", "exitCode", "forceError", "neverExecutedCleanupError",
    "observationError", "elapsedMilliseconds", "normalRequestMilliseconds", "forceAttemptMilliseconds",
    "stopError", "stopRequestedAtMilliseconds", "stopCompletedAtMilliseconds"))
OWNER_U32_FIELDS = frozenset(("expectedPid", "coreResult", "exitCode", "forceError",
                              "neverExecutedCleanupError", "observationError", "stopError"))


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate candidate/report JSON key")
        result[key] = value
    return result


def _bad_constant(_value):
    raise ValueError("nonfinite JSON")


def _finite(value):
    result = float(value)
    if not math.isfinite(result):
        raise ValueError("nonfinite JSON")
    return result


def _decode(image, maximum):
    if not image or len(image) > maximum:
        raise ValueError("candidate/report JSON size refused")
    value = json.loads(image.decode("utf-8"), object_pairs_hook=_unique,
                       parse_constant=_bad_constant, parse_float=_finite)
    if type(value) is not dict:
        raise ValueError("candidate/report must be an object")
    return value


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
                      allow_nan=False).encode("ascii")


def candidate_digest(candidate):
    return hashlib.sha256(_canonical(candidate)).hexdigest()


def _schema(value, keys):
    if type(value) is not dict or set(value) != set(keys):
        raise ValueError("exact reviewed schema required")


def _path(value):
    if type(value) is not str or not re.match(r"^[A-Za-z]:[\\/]", value):
        raise ValueError("absolute physical local path required")
    value = value.replace("/", "\\")
    parts = value[3:].split("\\")
    if len(value) > 1024 or any(ord(char) < 32 or char in '<>"|?*' for char in value) or ":" in value[2:] or any(
            not item or item in (".", "..") or item.endswith((" ", ".")) or
            re.fullmatch(r"CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9]", item.split(".", 1)[0], re.I)
            for item in parts):
        raise ValueError("ambiguous physical path declaration")
    value.encode("utf-8", "strict")
    return value


def _entry(value):
    _schema(value, ("path", "sha256"))
    path = _path(value["path"])
    if type(value["sha256"]) is not str or not HEX64.fullmatch(value["sha256"]):
        raise ValueError("lowercase declared SHA256 required")
    return path


def _source(entry, *, protection=None):
    path = Path(entry["path"])
    if protection is None:
        with path.open("rb") as stream:
            image = stream.read(1048577)
    else:
        image = protection.read_bytes(str(path), max_bytes=1048576)
    if len(image) > 1048576 or hashlib.sha256(image).hexdigest() != entry["sha256"]:
        raise ValueError("reviewed helper source changed")
    return image


def _load_source(entry, *, protection=None):
    # Compile exact checked source bytes. Never consult importlib/.pyc caches or
    # a helper imported via package.path/PYTHONPATH. Standard Python is trusted.
    image = _source(entry, protection=protection)
    name = "beamrt_reviewed_" + Path(entry["path"]).stem + "_" + entry["sha256"][:16]
    module = types.ModuleType(name)
    module.__file__ = entry["path"]
    sys.modules[name] = module  # dataclasses need their defining module present.
    try:
        exec(compile(image, entry["path"], "exec", dont_inherit=True), module.__dict__)
    except BaseException:
        sys.modules.pop(name, None)
        raise
    return module


def _fixture_arguments(files, directory):
    # Fixed local construction, not an imported helper's arbitrary argv. Every
    # executable and shader path must be the corresponding held manifest input.
    p = {role: entry["path"] for role, entry in files.items()}
    output = lambda leaf: ntpath.join(directory, leaf)
    return (p["host"], "--launch-reviewed", "--target", p["target"], "--dll", p["dll"],
        "--workdir", directory, "--expected-target-sha256", FIXTURE_PINS["target"][1],
        "--expected-dll-sha256", FIXTURE_PINS["dll"][1], "--acknowledge-native-insertion", "startup-observation-only",
        "--entry-rendezvous", "--observe-device-import", "--observe-gi-creation", "--gi-vertex", p["vertex"],
        "--expected-gi-vertex-sha256", FIXTURE_PINS["vertex"][1], "--gi-pixel", p["pixel"],
        "--expected-gi-pixel-sha256", FIXTURE_PINS["pixel"][1], "--pipeline-root-out", output("root.bin"),
        "--observe-gi-bindings", "--bindings-out", output("recorded-draw.bin"), "--observe-gi-resources",
        "--resource-descriptors-only", "--resource-interned-storage", "--owned-run-directory", directory,
        "--owned-run-token", TOKEN, "--owned-overall-seconds", "20", "--owned-normal-grace-seconds", "1",
        "--acknowledge-owned-force-close", "exact-created-child-after-normal-quit", "--owned-receipt-wait-seconds", "5",
        "--", "--device-backend", "warp", "--vs", p["vertex"], "--ps", p["pixel"],
        "--binding-case", "resource-interned", "--report", output("fixture-report.bin"),
        "--module", "beamrt_startup_bootstrap.dll", "--hold-ms", "0", "--exit-code", "0", "--",
        "", "space value", "ends\\", 'a\\"b', "\u96ea", "--launch-reviewed")


def review_candidate(candidate):
    """Read/check own helper source, return a plan; never claim/write or launch."""
    _schema(candidate, ("schema", "profile", "files", "helpers", "run_directory", "token", "limits"))
    if type(candidate["schema"]) is not int or candidate["schema"] != 1 or candidate["profile"] not in (FIXTURE_PROFILE, GAME_PROFILE):
        raise ValueError("unknown reviewed candidate profile")
    _schema(candidate["helpers"], HELPERS)
    own_directory = ntpath.normcase(ntpath.dirname(str(Path(__file__).absolute())))
    manifest = {}
    for leaf, entry in candidate["helpers"].items():
        path = _entry(entry)
        if ntpath.basename(path) != leaf or ntpath.normcase(ntpath.dirname(path)) != own_directory:
            raise ValueError("helper must be the fixed sibling source of this runner")
        manifest[path] = entry["sha256"]
    if type(candidate["token"]) is not str or not re.fullmatch(r"[0-9a-f]{32}", candidate["token"]):
        raise ValueError("explicit lowercase run token required")
    run_directory = _path(candidate["run_directory"])
    if type(candidate["files"]) is not dict:
        raise ValueError("explicit reviewed file declarations required")
    for entry in candidate["files"].values():
        path = _entry(entry)
        if path.casefold() in {item.casefold() for item in manifest}:
            raise ValueError("reviewed roles alias")
        manifest[path] = entry["sha256"]
    if candidate["profile"] == GAME_PROFILE:
        planner = _load_source(candidate["helpers"]["startup_plan.py"])
        plan = planner.build_plan(files=candidate["files"], run_directory=run_directory,
                                  token=candidate["token"], limits=candidate["limits"])
        argv, engine, lua_code = plan.host_argv, plan.engine_argv, plan.lua_code
    else:
        _schema(candidate["files"], FIXTURE_PINS)
        _schema(candidate["limits"], ("overall_timeout", "quit_grace", "receipt_wait"))
        if candidate["token"] != TOKEN or any(type(candidate["limits"][key]) is not int or candidate["limits"][key] != value
                for key, value in (("overall_timeout", 20), ("quit_grace", 1), ("receipt_wait", 5))):
            raise ValueError("fixture token/deadlines are fixed")
        for role, (leaf, digest) in FIXTURE_PINS.items():
            entry = candidate["files"][role]
            if ntpath.basename(entry["path"]) != leaf or entry["sha256"] != digest:
                raise ValueError("execution permits only exact fixed disposable artifacts")
        build = ntpath.dirname(candidate["files"]["host"]["path"])
        if any(ntpath.normcase(ntpath.dirname(candidate["files"][role]["path"])) != ntpath.normcase(build)
               for role in ("target", "dll", "vertex", "pixel")):
            raise ValueError("fixed fixture binary siblings required")
        for leaf in ("root.bin", "recorded-draw.bin.resources-start.bin", "fixture-report.bin.resource-report"):
            if len((run_directory + "\\" + leaf).encode("utf-16-le")) // 2 >= 260:
                raise ValueError("legacy native artifact path exceeds MAX_PATH")
        argv = _fixture_arguments(candidate["files"], run_directory)
        engine, lua_code = (), None
    aliases = [path.casefold() for path in manifest]
    if len(aliases) != len(set(aliases)) or len(manifest) != len(candidate["files"]) + len(HELPERS):
        raise ValueError("case-aliased input declaration")
    return {"candidateSHA256": candidate_digest(candidate), "profile": candidate["profile"],
            "declaredInputs": len(manifest), "hostArgv": tuple(argv), "engineArgv": tuple(engine),
            "luaCode": lua_code, "manifest": manifest, "runDirectory": run_directory,
            "gameExecutionAvailable": False, "outerChildFailsafeAvailable": False}


def _read_report(path, maximum=8192):
    attributes = Path(path).lstat()
    if not stat.S_ISREG(attributes.st_mode) or getattr(attributes, "st_file_attributes", 0) & 0x400:
        raise ValueError("nonphysical runtime report refused")
    with Path(path).open("rb") as stream:
        return _decode(stream.read(maximum + 1), maximum)


def _identity(value, token, expected_pid=None):
    if value.get("token") != token or type(value.get("expectedPid")) is not int or not 1 <= value["expectedPid"] <= 0xFFFFFFFF:
        raise ValueError("native context/report identity mismatch")
    if expected_pid is not None and value["expectedPid"] != expected_pid:
        raise ValueError("native context/report PID mismatch")


def _new_json(path, value):
    image = _canonical(value) + b"\n"
    with Path(path).open("xb") as stream:
        stream.write(image)
        stream.flush()
        os.fsync(stream.fileno())


def execute_fixture(candidate, expected_digest, *, acknowledge=True, protector_factory=None,
                    process_factory=None, clock=time.monotonic, sleep=time.sleep):
    """One protected fixed-fixture attempt. No production game execution exists.

    The retained host is never killed/reopened. A host timeout/crash cannot prove
    child exit; it is reported unknown. Native watcher cleanup is NOT an outer
    host-crash fail-safe. These limits are why Game profile execution refuses.
    """
    if type(candidate) is not dict or candidate.get("profile") != FIXTURE_PROFILE:
        raise ValueError("game execution disabled until independent exact-child cleanup exists")
    review = review_candidate(candidate)
    if type(expected_digest) is not str or expected_digest != review["candidateSHA256"]:
        raise ValueError("explicit reviewed candidate digest required")
    if type(acknowledge) is not bool:
        raise ValueError("explicit fixture acknowledgement policy required")
    if os.name != "nt" and process_factory is None:
        raise OSError("fixed native fixture requires Windows")
    if protector_factory is None:
        protection_module = _load_source(candidate["helpers"]["protected_inputs.py"])
        protector_factory = protection_module.ProtectedInputs
    protection = protector_factory(review["manifest"], review["runDirectory"])
    process = None
    result = {"profile": FIXTURE_PROFILE, "candidateSHA256": expected_digest, "status": "refused",
              "hostExitVerified": False, "nativeReportedChildExitVerified": False,
              "independentChildExitVerified": False, "outerChildFailsafeAvailable": False,
              "gameExecutionAvailable": False, "ackValidated": False, "fixtureAckConsumed": False}
    try:
        protection.open()
        # Verify and execute the exact held source, bypassing stale .pyc files.
        ack_module = _load_source(candidate["helpers"]["receipt_ack.py"], protection=protection)
        handoff_module = _load_source(candidate["helpers"]["receipt_handoff.py"], protection=protection)
        protection.claim_attempt(candidate["token"], expected_digest)
        directory = Path(review["runDirectory"])
        _new_json(directory / "runner-plan.json", {key: value for key, value in review.items() if key != "manifest"})
        last = None

        def now():
            nonlocal last
            value = clock()
            if type(value) not in (int, float) or not 0 <= value <= 2**53 or not math.isfinite(value) or (last is not None and value < last):
                raise ValueError("invalid/regressing runner clock")
            last = value
            return value

        started = now()
        ready_deadline, host_deadline = started + 12, started + 40
        with (directory / "runner-host.log").open("xb") as log:
            factory = process_factory or subprocess.Popen
            process = factory(review["hostArgv"], stdout=log, stderr=subprocess.STDOUT,
                              cwd=ntpath.dirname(candidate["files"]["host"]["path"]), shell=False,
                              close_fds=True, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            expected_pid, ack, diagnostic_failed = None, None, False
            try:
                while not (directory / "receipt-ready.json").exists():
                    if process.poll() is not None:
                        raise ValueError("native host exited before ready; child exit not independently known")
                    if now() >= ready_deadline:
                        raise TimeoutError("runner receipt-ready deadline expired")
                    sleep(0.02)
                context = _read_report(directory / "process-context.json", 4096)
                _schema(context, ("token", "expectedPid"))
                _identity(context, candidate["token"])
                expected_pid = context["expectedPid"]  # File join only, never process control.
                if acknowledge:
                    ack = handoff_module.wait_and_ack(directory, expected_pid, candidate["token"],
                        Path(candidate["files"]["decoder"]["path"]), timeout_seconds=1,
                        publisher=ack_module.publish_ack)
                    result["ackValidated"] = True
            except (OSError, ValueError, TimeoutError, subprocess.SubprocessError) as error:
                diagnostic_failed = True
                result["reason"] = str(error)
            # Poll the retained HOST handle only. Never wait unbounded in a finally
            # clause and never kill the host (which could orphan its exact child).
            try:
                while process.poll() is None and now() < host_deadline:
                    sleep(0.02)
            except (ValueError, OSError) as error:
                diagnostic_failed = True
                result["reason"] = str(error)
            host_code = process.poll()
            result["hostExitVerified"] = host_code is not None
            result["hostExitCode"] = host_code
            if host_code is None:
                result["status"] = "host_exit_unconfirmed"
                result["reason"] = "host still active; independent child cleanup unavailable"
            else:
                try:
                    owner = _read_report(directory / "owned-exit.json")
                    _schema(owner, OWNER_BOOL_FIELDS | OWNER_NUMBER_FIELDS | {"token"})
                    _identity(owner, candidate["token"], expected_pid)
                    for field in OWNER_BOOL_FIELDS:
                        if type(owner.get(field)) is not bool:
                            raise ValueError("native exit report type mismatch")
                    for field in OWNER_NUMBER_FIELDS:
                        maximum = 0xFFFFFFFF if field in OWNER_U32_FIELDS else 0xFFFFFFFFFFFFFFFF
                        if type(owner.get(field)) is not int or not 0 <= owner[field] <= maximum:
                            raise ValueError("native exit report number mismatch")
                    if owner["processExitVerified"] and owner["observationError"]:
                        raise ValueError("native exit proof contradicts observation error")
                    if not owner["resumeAttempted"] or not owner["resumed"] or owner["beforeResumeTimedOut"] or \
                            owner["neverExecutedCleanupAttempted"] or owner["neverExecutedCleanupCallSucceeded"] or owner["neverExecutedCleanupError"]:
                        raise ValueError("native report does not describe the executed fixture")
                    result["nativeReportedChildExitVerified"] = owner["processExitVerified"]
                    result["nativeChildExitCode"] = owner["exitCode"]
                    result["nativeForceAttempted"] = owner["forceAttempted"]
                    if acknowledge and ack is not None:
                        consumed = _read_report(directory / "fixture-ack-consumed.json", 4096)
                        if consumed != {"token": candidate["token"], "expectedPid": expected_pid,
                                        "kind": "fixture_ack_consumed", "digest": ack["digest"]}:
                            raise ValueError("fixture ACK consumption mismatch")
                        _identity(consumed, candidate["token"], expected_pid)
                        result["fixtureAckConsumed"] = True
                        passed = host_code == 0 and owner["coreResult"] == 0 and owner["exitCode"] == 0 and not owner["normalRequested"]
                    else:
                        passed = not acknowledge and host_code == 17 and owner["exitCode"] == 98 and owner["normalRequested"]
                    passed = passed and not diagnostic_failed and owner["processExitVerified"] and not owner["forceAttempted"] and owner["observationError"] == 0
                    result["status"] = "fixture_pass" if passed else "fixture_failed"
                except (OSError, ValueError) as error:
                    result["status"], result["reason"] = "native_child_state_unknown", str(error)
        _new_json(directory / "runner-result.json", result)
        return result
    except (OSError, ValueError, TimeoutError, subprocess.SubprocessError) as error:
        if process is None:
            raise
        # Diagnostics can fail after spawn (clock, sleeper, poll or file I/O).
        # Make one best-effort retained-host query; never retry with an invalid
        # clock, block indefinitely, terminate the host or reopen a child PID.
        try:
            host_code = process.poll()
        except (OSError, ValueError, subprocess.SubprocessError):
            host_code = None
        result["hostExitVerified"], result["hostExitCode"] = host_code is not None, host_code
        result["status"] = "host_exit_unconfirmed" if host_code is None else "native_child_state_unknown"
        result["reason"] = str(error)
        result["nativeReportedChildExitVerified"] = False
        result["fixtureAckConsumed"] = False
        try:
            _new_json(Path(review["runDirectory"]) / "runner-result.json", result)
        except OSError as output_error:
            result["reportPublicationError"] = str(output_error)
        return result
    finally:
        # Retained locks end when this bounded runner exits. An unknown host/child
        # remains unknown; this is not a claim of independent cleanup protection.
        protection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--execute-reviewed-fixture", action="store_true")
    parser.add_argument("--expected-candidate-sha256")
    parser.add_argument("--withhold-fixture-ack", action="store_true")
    args = parser.parse_args()
    try:
        with args.candidate.open("rb") as stream:
            candidate = _decode(stream.read(131073), 131072)
        if args.execute_reviewed_fixture:
            result = execute_fixture(candidate, args.expected_candidate_sha256, acknowledge=not args.withhold_fixture_ack)
            print(json.dumps(result, indent=2))
            return 0 if result["status"] == "fixture_pass" else 2
        if args.expected_candidate_sha256 is not None or args.withhold_fixture_ack:
            raise ValueError("execution acknowledgement is not accepted in review mode")
        result = review_candidate(candidate)
        result.pop("manifest")
        print(json.dumps(result, indent=2))
        return 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("Protected runner refused: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
