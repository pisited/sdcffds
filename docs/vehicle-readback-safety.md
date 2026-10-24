# Vehicle acquisition hardening and controlled retry

The opt-in single-car diagnostic below completed one live geometry-only
copy/validation/free, including the previously implicated prop. Following that
result and explicit user approval, pair revision 8 enables a sequential
[two-car CPU control experiment](two-car-offscreen-test.md#current-experiment-revision-8-geometry-only-cpu-controls)
using the same profile and instrumented provider. The original native crash is
not conclusively diagnosed; this does not establish the remaining native getters
are safe. The subsequent live pair CPU control completed all four checks;
[its recorded result](two-car-offscreen-test.md#live-cpu-control-result---october-23)
is acquisition/geometric evidence, not a reflection or native-safety guarantee.

## Controlled single-car experiment

Start/restart BeamNG with the updated files, enter one parked car and pause
physics with J. Do not run the vehicle exporter/recording, glass-sunlight capture,
or other mesh-readback tools alongside this test. It owns one handle, not a
global engine-wide GPUMesh lock. Leave camera, vehicle placement and renderer
settings unchanged. In the **GE Lua** console run once:

```lua
extensions.load('beamrt_vehicleReadbackProbe'); local ok,why=extensions.beamrt_vehicleReadbackProbe.start(); print(tostring(ok)..': '..tostring(why))
```

Then inspect the compact result:

```lua
print(jsonEncode(extensions.beamrt_vehicleReadbackProbe.getStatus()))
```

`start()` selects the currently controlled car instead of assuming the old IDs
survived a restart. It requires paused physics and a stable vehicle/pose/material
identity. It requests one native handle, polls readiness, borrows it for the
`geometry` provider profile, validates CPU positions/indices, drops its CPU cache
and attempts native free once. No wireframe, rays, shading or scene edits run.
A `complete` result is historical acquisition/range-check evidence, not current
geometry freshness, complete alignment, or any kind of reflection proof.

Each request/readiness/copy/free boundary appends a small JSON line to
`/settings/beamrtVehicleReadbackStages.jsonl` in BeamNG's user folder (normally
`current/settings/beamrtVehicleReadbackStages.jsonl`). It records a run ID,
vehicle ID, sequence, operation, submesh index/name and before/after boundary;
it does not export geometry or GPU buffers. Every entry is flushed and closed
before continuing. This improves process-crash evidence, **not** power-loss/disk
durability. A last `before` without its matching `after` narrows the operation
in progress; it does not exclude corruption originating earlier.

Stage-journal failure prevents the next capture call; an already-owned handle
still receives its one cleanup attempt. Cleanup uncertainty blocks further
starts in that extension instance: restart BeamNG, do not reload to bypass it.
Native exceptions can still terminate the process despite Lua `pcall`. A stale
provider API is rejected before requesting a handle; restart rather than forcing
package-cache replacement while another consumer may own data.

## Evidence and uncertainty

The 2026-10-23 main-thread crash occurred during acquisition, before CPU rays
began. The contextual GELUA stack pointed at the prop color getter for
`ardente_paddles`, native prop index 4, with 479 reported colors/vertices. The
minidump records a native read access violation at address `0x48`; engine symbols
are unavailable, so stream validity, native lifetime and earlier corruption have
not been conclusively distinguished. See [the incident record](two-car-offscreen-test.md).

Installed BeamNG sources checked directly:

- `lua/ge/extensions/util/export.lua`: the exporter uses one retained native
  readback, polls readiness and frees it when finished/replaced. Normals default
  on; tangents, UVs and colors default off. This is not proof that multiple
  outstanding handles are forbidden, or that readiness guarantees every stream.
- `lua/common/cdefGpuMesh.lua`: the active `gpuPrimitive_t` has three `uint32_t`
  fields at offsets 0/4/8, size 12. The older whole-mesh structures in the same
  file are **commented out**, not a current raw-pointer ABI contract.

## Narrow buffer profiles

`vehicleProvider.capture(id, readyMesh, profile, observer)` defaults to `geometry`:
positions, indices and primitive/material-name identity only. It does not even
look up optional color/normal/tangent/UV counts or getters. Colors are disabled
for all profiles; a positive reported color count is not treated as proof of a
valid native stream. There is no full/color profile or runtime opt-in flag.

The explicit `glass` profile adds shared flexmesh UV0 (`uv1Get` in BeamNG's API),
which the existing glass consumer actually requires. Prop meshes remain
geometry-only, because that consumer rejects exterior-window props and does
not need their UVs. Missing requested UVs fail the acquisition; no fake UVs or
opaque fallback are substituted. The glass caller now names its profile.

Excluded counts are zero and their CPU buffers absent. This means **not
acquired**, not that the live source lacks those attributes. Material shading,
alpha coverage and complete scene geometry remain unverified.

Counts/ranges must be finite integers within explicit limits; invalid values
are rejected, not floored or truncated. CPU destinations are bounded to 32 MiB
per vehicle, with 500k vertices per buffer, 1.5m indices per buffer, 256 submeshes
per kind and 2048 primitives total. Primitive FFI size/offsets are checked before
copying. These checks do not bound the engine's initial native allocation or
protect against a C++ getter writing past its declared destination.

## Ownership contract

The provider no longer initiates a readback when no handle is supplied. Both
`capture(id)` and `rebuild` without a caller-owned ready handle fail explicitly;
the old manual `main.captureVehicleGeometry(id)` consequently cannot silently
create a native request. No implicit acquire-and-forget path remains in this
provider.

The lifecycle owner requests and polls **one** handle, lends it synchronously to
the provider, receives independent FFI CPU arrays/plain metadata, and frees the
native handle once. The provider never frees it, even on an error; returned
records and its cache do not retain native userdata. Invalidation drops only CPU
cache references and cannot free a handle still owned elsewhere. An existing
cached record must be explicitly invalidated before replacement.

The pair controller is prepared to process A to completion and release it before
requesting B, while checking both car poses/identities/physics throughout. Failed
or uncertain cleanup prevents the second request. This sequencing follows the
installed exporter pattern but is not a proven repair for the observed crash.
Revision 8 permits this narrow opt-in sequence after explicit user approval;
every native acquisition/copy/free phase writes its own pair stage journal.
This is not an unrestricted optional-stream or GPU rendering path.

## Offline validation boundary

Tests use actual LuaJIT FFI allocations with Lua-owned fake getters. Tripwires
raise if an excluded optional count/getter is even looked up; the crash-shaped
479-color prop has a getter that must never execute. Tests also cover required
stream failures, unready handles, ABI mismatches, cache isolation, no implicit
request/free, and A-release-before-B-request ordering. Glass UV selection and
the stale-provider rejection are checked separately.

Current lifecycle tests use the shipped controller source unchanged, but every
native getter and journal handle is a Lua-owned fake. Passing these tests does
**not** validate the game DLL or close the native crash investigation.
