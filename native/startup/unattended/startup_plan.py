"""Pure, review-only argument plan for a separately protected observation candidate.

This module never reads the supplied paths, verifies their declared hashes,
claims a directory, starts a process, or grants launch authority. The caller
must independently retain and verify the already-reviewed physical inputs.
Even its generated native argv explicitly selects --review. There is no CLI
or execution helper. Queued Lua ordering before map startup remains unproven;
the existing early shim refuses late attachment instead of guessing readiness.
"""

from collections.abc import Mapping
from dataclasses import dataclass
import math
import ntpath
import re
import subprocess
import unicodedata


DECODER_SHA256 = "0aac455d357fdb8414f95c92cb539f8154136e5b6a48fe49971f7525ef65f804"
ROLES = frozenset(("host", "target", "dll", "vertex", "pixel", "early_shim",
                   "bootstrap", "adapter", "controller", "decoder"))
LIMITS = {
    "load_timeout": (1, 300), "capture_timeout": (1, 120),
    "overall_timeout": (1, 480), "stable_seconds": (0.1, 5),
    "stable_frames": (2, 60), "quit_grace": (1, 30),
    "shim_timeout": (1, 30), "receipt_wait": (1, 30),
}
LEAVES = {
    "host": "beamrt_startup_host.exe", "target": "BeamNG.drive.x64.exe",
    "dll": "beamrt_startup_bootstrap.dll", "early_shim": "early_shim.lua",
    "bootstrap": "bootstrap.lua", "adapter": "engine_adapter.lua",
    "controller": "controller.lua", "decoder": "receipt_decoder.exe",
}
_RESERVED = re.compile(r"(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])", re.ASCII)
_HEX64 = re.compile(r"[0-9a-f]{64}", re.ASCII)
_TOKEN = re.compile(r"[0-9a-f]{32}", re.ASCII)


@dataclass(frozen=True)
class StartupPlan:
    """Argument vectors only; not an executable launcher or authorization."""

    host_argv: tuple[str, ...]
    engine_argv: tuple[str, ...]
    lua_code: str
    token: str
    run_directory: str


def _utf16_length(value):
    try:
        return len(value.encode("utf-16-le", "strict")) // 2
    except UnicodeError as error:
        raise ValueError("unpaired Unicode surrogate") from error


def _path(value, *, directory=False, short=False):
    if not isinstance(value, str) or not value:
        raise ValueError("explicit absolute local physical path required")
    # Physical identity, fixed-drive status and absence of reparse components
    # cannot be established lexically. Those are the protecting caller's job.
    path = value.replace("/", "\\")
    if (not re.match(r"^[A-Za-z]:\\", path, re.ASCII)
            or any(unicodedata.category(char) in {"Cc", "Cf", "Cs", "Zl", "Zp"}
                   or char in '<>"|?*' for char in path)
            or ":" in path[2:] or "\\\\" in path[2:]):
        raise ValueError("noncanonical local path")
    if directory and path.endswith("\\"):
        path = path[:-1]
    parts = path[3:].split("\\")
    if not parts or any(not part or part in (".", "..") or part.endswith((" ", "."))
                        or _RESERVED.fullmatch(part.split(".", 1)[0].upper()) for part in parts):
        raise ValueError("ambiguous or reserved path component")
    size = _utf16_length(path)
    if size > 1024 or (short and size >= 260):
        raise ValueError("path exceeds reviewed path bound")
    try:
        if len(path.encode("utf-8", "strict")) > (1024 if directory else 2048):
            raise ValueError("path exceeds Lua byte bound")
    except UnicodeError as error:
        raise ValueError("invalid Unicode path") from error
    return path


def _lua_string(value):
    # An ASCII-only Lua source literal for the exact UTF-8 bytes avoids relying
    # on locale or long-bracket delimiters. Three-digit decimal escapes cannot
    # swallow a following digit, and work in both Lua 5.1 and LuaJIT 2.1.
    pieces = ["'"]
    for byte in value.encode("utf-8"):
        if byte in (39, 92):
            pieces.append("\\" + chr(byte))
        elif 32 <= byte <= 126:
            pieces.append(chr(byte))
        else:
            pieces.append("\\%03d" % byte)
    pieces.append("'")
    return "".join(pieces)


def _number(value):
    return str(value) if isinstance(value, int) else format(value, ".17g")


def _command_bound(arguments):
    # No shell is involved. list2cmdline is used solely to conservatively check
    # the actual Windows UTF-16 command-line bound, including terminating NUL.
    if _utf16_length(subprocess.list2cmdline(arguments)) >= 32767:
        raise ValueError("Windows command-line bound exceeded")


def build_plan(*, files, run_directory, token, limits):
    """Return an inert fixed-mode plan from explicit declarations only.

    ``files`` has exactly ROLES, each an exact ``{path, sha256}`` mapping.
    ``limits`` has exactly LIMITS. No extra native or engine arguments exist.
    Hash strings are declarations, not evidence of file contents or ownership.
    """
    if not isinstance(files, Mapping) or set(files) != ROLES:
        raise ValueError("exact reviewed file roles required")
    paths, hashes = {}, {}
    for role in sorted(ROLES):
        entry = files[role]
        if not isinstance(entry, Mapping) or set(entry) != {"path", "sha256"}:
            raise ValueError("exact path/hash declaration required")
        path = _path(entry["path"], short=role in {"host", "target", "dll", "vertex", "pixel", "decoder"})
        digest = entry["sha256"]
        if not isinstance(digest, str) or not _HEX64.fullmatch(digest):
            raise ValueError("lowercase SHA-256 declaration required")
        if role in LEAVES and ntpath.basename(path) != LEAVES[role]:
            raise ValueError("unexpected reviewed role leaf")
        if role == "target" and ntpath.basename(ntpath.dirname(path)) != "Bin64":
            raise ValueError("reviewed game target must be directly inside Bin64")
        if role in {"vertex", "pixel"} and not path.endswith(".cso"):
            raise ValueError("explicit shader bytecode path required")
        if role == "dll" and not path.isascii():
            raise ValueError("Detours bootstrap path must be ASCII")
        if role == "decoder" and digest != DECODER_SHA256:
            raise ValueError("decoder differs from pinned ABI7 validator")
        paths[role], hashes[role] = path, digest
    if len({path.casefold() for path in paths.values()}) != len(paths):
        raise ValueError("reviewed file roles alias")
    directory = _path(run_directory, directory=True)
    if not isinstance(token, str) or not _TOKEN.fullmatch(token):
        raise ValueError("32 lowercase hexadecimal run token required")
    if not isinstance(limits, Mapping) or set(limits) != set(LIMITS):
        raise ValueError("exact bounded limits required")
    settings = {}
    for name, (low, high) in LIMITS.items():
        value = limits[name]
        if (isinstance(value, bool) or not isinstance(value, (int, float)) or not low <= value <= high
                or not math.isfinite(value) or name != "stable_seconds" and not isinstance(value, int)):
            raise ValueError("invalid bounded limit: " + name)
        settings[name] = value
    root = directory + "\\root.bin"
    record = directory + "\\recorded-draw.bin"
    outputs = (root, record, *(record + suffix for suffix in
                (".threads.bin", ".thread-samples.bin", ".resources-start.bin", ".resources.bin")))
    for output in outputs:
        _path(output, short=True)
        if output.casefold() in {path.casefold() for path in paths.values()}:
            raise ValueError("runtime output aliases a reviewed input")
    # The adapter bounds each starting argument to 8192 UTF-8 bytes. Keep the
    # generated script one line with only literal paths, token and bounded data.
    lua_path = lambda role: _lua_string(paths[role].replace("\\", "/"))
    controller = "{" + ",".join((
        "token=" + _lua_string(token), "expectedLevel='west_coast_usa'",
        "loadTimeout=" + _number(settings["load_timeout"]),
        "captureTimeout=" + _number(settings["capture_timeout"]),
        "overallTimeout=" + _number(settings["overall_timeout"]),
        "stableSeconds=" + _number(settings["stable_seconds"]),
        "stableFrames=" + _number(settings["stable_frames"]),
        "quitGrace=" + _number(settings["quit_grace"]))) + "}"
    config = ("{timeout=" + _number(settings["shim_timeout"])
        + ",bootstrapSourcePath=" + lua_path("bootstrap") + ",bootstrap={runDirectory="
        + _lua_string(directory.replace("\\", "/")) + ",controllerSourcePath=" + lua_path("controller")
        + ",adapterSourcePath=" + lua_path("adapter") + ",controller=" + controller + "}}")
    code = ("do local factory=dofile(" + lua_path("early_shim")
        + "); assert(type(factory)=='table' and type(factory.new)=='function','invalid_early_factory');"
        + " local shim=factory.new(" + config + ",_G); shim.arm(" + _lua_string(token) + ") end")
    if len(code.encode("utf-8")) > 8192:
        raise ValueError("queued Lua exceeds starting-argument byte bound")
    engine = ("-level", "west_coast_usa", "-beamrtObservationToken", token, "-lua", code)
    native = (paths["host"], "--review", "--target", paths["target"], "--dll", paths["dll"],
        "--workdir", ntpath.dirname(ntpath.dirname(paths["target"])),
        "--expected-target-sha256", hashes["target"], "--expected-dll-sha256", hashes["dll"],
        "--acknowledge-native-insertion", "startup-observation-only", "--entry-rendezvous",
        "--observe-device-import", "--observe-gi-creation", "--gi-vertex", paths["vertex"],
        "--expected-gi-vertex-sha256", hashes["vertex"], "--gi-pixel", paths["pixel"],
        "--expected-gi-pixel-sha256", hashes["pixel"], "--pipeline-root-out", root,
        "--pipeline-wait-seconds", str(settings["load_timeout"]), "--observe-gi-bindings",
        "--bindings-out", record, "--bindings-wait-seconds", str(settings["capture_timeout"]),
        "--observe-gi-resources", "--resource-descriptors-only", "--resource-interned-storage",
        "--owned-run-directory", directory, "--owned-run-token", token,
        "--owned-overall-seconds", str(settings["overall_timeout"]),
        "--owned-normal-grace-seconds", str(settings["quit_grace"]),
        "--acknowledge-owned-force-close", "exact-created-child-after-normal-quit",
        "--owned-receipt-wait-seconds", str(settings["receipt_wait"]), "--", *engine)
    _command_bound((paths["target"], *engine))
    _command_bound(native)
    return StartupPlan(native, engine, code, token, directory)
