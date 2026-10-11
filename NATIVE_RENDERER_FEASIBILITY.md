# BeamRT native clustered-light integration feasibility

Date: 2026-10-11. **Current decision: no ReShade dependency.** The earlier
ReShade add-on assessment below is retained as evidence, not the selected plan.
A direct BeamNG rendering plug-in is not supported by any verified interface
we have found. Resource access remains the unproven part of the native milestone.

Update v0.108: exact-adapter D3D12 candidate acquisition and resource-owner device
checks are implemented/tested offline, using documented SDK calls rather than
engine exports. [NATIVE_DEVICE_BOOTSTRAP_V0108.md](NATIVE_DEVICE_BOOTSTRAP_V0108.md)
records the route and its limits. Real frame resource access is still missing;
device acquisition alone does not pass the in-game integration gate.

The user subsequently asked to continue. A small no-ReShade native BVH GPU worker
has now been built and loaded **only in its separate offline self-test process**.
The real guardhouse GPU queries passed on the RTX 4070; synthetic WARP tests also
passed. See [native/worker/README.md](native/worker/README.md). No BeamNG attachment,
game DLL installation/injection, game-file/setting or process memory modification
was performed. Existing rendering and the default-off clustered guard remain.

## Evidence checked

- Installed executable version: `0.39.4.0.20972`. Current game log confirms an
  NVIDIA RTX 4070 on Direct3D 12. Other graphics backends are outside the first
  prototype's scope.
- Read-only PE export inspection: BeamNG.drive.x64.exe has 18 named exports,
  including debug drawing, UI/SSL and GPU preference symbols, but no clustered
  dispatch, graphics-device or geometry-resource binding API.
- libbeamng.x64.dll has three named exports: getBeamEngine,
  destroyBeamEngine and getBeamEngineRevision. These names do not supply a
  documented rendering interface or authorize guesses about object layouts.
- No engine rendering SDK headers/import libraries were located in the installed
  game tree. A later vswhere query located the installed MSVC toolchain at
  `E:\New folder (3)`; MSVC and Windows SDK FXC compiled the offline worker.
- No ReShade.ini or usual dxgi.dll/d3d12.dll host was found at the checked game
  root/Bin64 paths. This is not an exhaustive claim about every possible loader.
- Installed clustered shade source SHA-256:
  `697e24d29767f85ad8cfd31f3265e4d771998eaa791aebff661aeb16c4c2e9ff`.
  This is a **source** fingerprint, not the executing compiled pipeline hash.
- BeamNG documents a closed-source C++ rendering core. Its official ROS 2 native
  example is a sensor/simulation interface: the inspected API describes shared
  memory streams, vehicle state and controls, not renderer device handles.
  Its GPU sensor terminology must not be mistaken for GPU resource binding.

Primary sources: [BeamNG architecture](https://documentation.beamng.com/beamng_tech/architecture/),
[ROS native integration](https://documentation.beamng.com/api/ros2/main/beamng_ros2/user_docs/cpp_bridge.html),
[inspected ROS API](https://github.com/BeamNG/beamng-ros2-integration/blob/f684d48eec39c9f2a49f884a175c1aea7dd82ca6/beamng_ros2/src/api.h).

## Previously assessed ReShade add-on route (not selected)

This proposal uses ReShade's **native add-on API**, not a fullscreen ReShade
effect. Its documented interface supplies compute pipeline creation, pipeline
layout/resource binding and command-list dispatch callbacks. The official shader
replacement example includes compute shaders. Those are relevant capabilities
for attaching our geometry before native light contributions are evaluated.

Inspected upstream revision: `7bf9de8b33bcc76c3177007e65d73c72dd0f34c0`.
Sources: [API reference](https://github.com/crosire/reshade/blob/7bf9de8b33bcc76c3177007e65d73c72dd0f34c0/REFERENCE.md),
[event contracts](https://github.com/crosire/reshade/blob/7bf9de8b33bcc76c3177007e65d73c72dd0f34c0/include/reshade_events.hpp),
[device/resource API](https://github.com/crosire/reshade/blob/7bf9de8b33bcc76c3177007e65d73c72dd0f34c0/include/reshade_api_device.hpp),
[compute-capable replacement example](https://github.com/crosire/reshade/blob/7bf9de8b33bcc76c3177007e65d73c72dd0f34c0/examples/06-shader_replace/shader_replace_addon.cpp).

Inference: these capabilities make an API-level integration plausible without
private engine-address scans. They do not establish that this BeamNG build's
specific pipeline, root layout and command submission can be intercepted safely.
ReShade full add-on support is an additional host dependency and its installation
requires separate approval. No download, installer or sandbox change was made.

## Historical add-on implementation requirements (not the current host choice)

Build an offline Direct3D 12-only add-on plus a matching compute shader variant.
Reuse one real imported underground instance, its native transform and declared
opaque material policy. Do not create fake lights or reconstruct live light
intensity from vehicle declarations.

1. Identify the actual native shade pipeline through compiled shader identity
   and its resource/layout contract. Do not select every compute pass, match
   thread-group dimensions alone, or equate exposed ClusteredShading with active
   routing. Confirm depth/lighting permutations and the native buffer structures.
2. Capture the matching native pipeline layout and command-list bindings. Create
   a private compatible pipeline/layout with separate geometry/instance inputs;
   preserve native parameter indices, static samplers and descriptor meanings.
   Merely replacing shader bytes does not extend a Direct3D 12 root signature.
3. Upload our existing packed geometry once per immutable scene generation on
   the same graphics device. Consume the native light list, cookies, receiver
   reconstruction, exposure and actual current light positions/intensity.
4. In the matching replacement pass, apply additional definite-opaque visibility
   after the native shadowStrength lerp and before diffuse/specular/retro use.
   Respect native disableShadows views. Leave native shadowing and ambiguous
   mesh coverage unchanged; do not change ambient, sun, emissive or reflections.
5. Issue exactly one local-light accumulation: either the validated replacement
   or the original, never both. Restore the original command-list state before
   following game commands. Prepare every fallible resource/pipeline operation
   before recording writes to native lighting targets.

## Required safety gates

- Default OFF; unsupported API, host version, shader identity, permutation,
  layout or missing scene state must leave native dispatch unchanged.
- Track state separately per command list; clear it on reset and account for
  root descriptors/constants, descriptor heaps/tables, bundles and indirect
  dispatch. Unsupported submission forms must keep native behavior.
- Do not globally modify a shared native root signature or reuse its atlas/
  cookie registers for mesh data. Any additional binding must be explicitly
  provided by the private layout, not guessed from an unused shader register.
- Synchronize uploads, queue use and resource retirement with GPU completion.
  Do not destroy geometry while an in-flight command list references it.
- Associate scene generation with object/mission lifetime and transform/material
  validity. Walking/driving changes must not remove static casters. Stale or
  incompatible state falls back, not arbitrary geometry at old world positions.
- Device removal, resize/HDR recreation, shader reload and host teardown require
  explicit ownership/lifetime handling. Compatibility failure must be reported
  as unsupported, not successful activation.
- Keep local-light attenuation, BRDF, exposure and native contributions intact.
  No CPU GPU-light readback, invented brightness or final-image darkness filter.

## Risks / what remains unverified

Actual pipeline interception and complete root-state restoration are the largest
risks. A mismatch can cause missing lighting, double accumulation, invalid GPU
access or a crash. Native shader/cache revisions and other add-ons can conflict.
The graphics-API route still depends on this game's lighting ABI and will not
automatically support Vulkan or all future BeamNG releases.

Full-resolution per-light BVH queries may be too expensive for gameplay. The
first slice must use receiver/segment-to-instance bounds rejection and a bounded
traversal, then measure GPU cost. An RTX 4070 is not a performance guarantee.
One section cannot cover an entire sewer; unknown alpha materials remain native.
Correct local shadows do not solve sky/ambient fill or GI secondary visibility.

## Next milestone and validation boundary

The offline GPU worker is real implementation progress, but proves neither
native camera/depth access nor output consumption by BeamNG. Do not expand it
into an unrelated complete renderer while the connection is unproven.

Next is a verified **no-ReShade host adapter** supplying the actual game device,
camera/depth, command execution/synchronization and an intended lighting consumer.
No such adapter has been implemented or installed. Loading the worker with
ffi.load does not provide those capabilities; the installed external-DLL example
also requires a disabled Lua sandbox, which we have not changed.

Before any deployment, review the exact adapter, installation/removal steps and
compatibility gates with the user. Then perform one bounded comparison proving
actual world-mesh visibility affects intended lighting and disable restores the
original rendering. No overlay-only success, repeated proxy lookup, guardhouse
alignment or unchanged legacy-path comparison establishes that connection.
