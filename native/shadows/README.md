# Offline sunlight producer/consumer audit — 2026-10-13

All devices, queues, textures, projection constants and meshes in this fixture
belong to its executable. BeamNG stayed closed. No game files/settings, active
materials, native startup hooks or GI adapter contracts were changed.

## Confirmed shader fixes

The old `beamrtMeshSunReceiver` accepted a NaN relay-position component as
matching a finite lighting receiver: its greater-than comparison did not reject
it. A blocked sentinel then manufactured an opaque shadow. A nonfinite lighting
receiver could similarly match. Both now reject the relay and retain native
visibility. Coordinates are checked before conversion to texture indices.

The actual sunlight producer also marked nonfinite sun direction/sign, camera
origin, invalid decoded depth and a NaN enable flag as usable visibility data.
Those inputs now produce an invalid sentinel, preserving native lighting.

Ordinary finite tracing, geometry layout, material policy, native/cloud mixing,
200-unit reach, 0.035 normal offset and 0.05 ray-start cutoff are unchanged.
No stronger shadows, finished-image darkening or new denoising was introduced.

## Verification and evidence

The GPU fixture executes the **actual** `beamrtMeshSunVisibilityP_v001.hlsl`
pixel shader compiled against installed BeamNG headers. Its texture is consumed
on the same owned queue by the **exact** `beamrtResolveSunVisibility` function
from `beamrtMeshSunHook.h.hlsl`. The controlled consumer keeps ambient separate
from direct light and checks GPU pixels. It is not the complete native
vector-light BRDF/MRT pipeline.

Mesh blockers are absent from the receiver-only depth buffer. Cases cover
opaque/thin zero-thickness faces, self/behind/bias-excluded faces, nonuniform and
mirrored transforms, uncertain material fallback, receiver position/resolution
mismatch, four comparison modes, OFF/ON, bad mesh/relay/camera/light/depth data,
and recovery.

- Original shaders: **34/43** GPU checks on both RTX 4070 and WARP; nine invalid
  cases failed per backend. Exact artifacts/sources/logs retained under ignored
  `.beamrt-validation/sun-shadows-red-a8868891542542a09a89172a62a9b97c`.
- Repaired shaders plus two transform cases: **45/45** on both backends. Frozen
  artifacts/logs retained under ignored
  `.beamrt-validation/sun-shadows-green-9caa93d4c22743d7a289c53dcbed11db`.
- **32** prepared native vector-light PS permutations compile with installed
  headers: four comparison modes, no-shadow, SSAO and SSS combinations. Compile
  evidence is not full native lighting-pass execution.
- **216/216** Python/Lua/source tests pass. GI pixel-producer/consumer, capture
  handoff and post-consumer retirement regressions pass on RTX and WARP after
  sharing the unchanged offline GPU host via `native/gi/gpu_fixture_host.h`.
- D3D12 debug layer unavailable; no debug-layer-clean claim.

Producer source SHA256:
`931703a57d388169c6cb48cefe8ed18b868a1e73536d716a0d7637a136551452`.
Hook source SHA256:
`5c849791a160fdd50f93234d1f6800f3d2c13f158bbd0965785b4fcacd7bbe64`.

The ignored local prepared manifest was refreshed against this game, yielding
hybrid `beamrtVectorLight_6323cd65470cabdc.hlsl`. Old prepared files remain under
`.beamrt-validation/sun-prepared-before-61e5243e6a4240e78a2607ac5a38d5ea`.
This is preparation only, not activation or material rebinding. The previously
successful frozen live host/bootstrap hashes remain unchanged.

## Run locally

```powershell
./native/shadows/build.ps1 -NativeIncludes 'E:/SteamLibrary/steamapps/common/BeamNG.drive' -RunTest
./native/shadows/build.ps1 -NativeIncludes 'E:/SteamLibrary/steamapps/common/BeamNG.drive' -RunTest -Warp
```

`tools/tests/validate_sun_light_shaders.py` separately compiles an already
prepared manifest and refuses changed dependencies. CI runs source guards
without redistributing proprietary game headers.

## Remaining boundary

Synthetic GPU cases do not prove live sunlight bindings/order, full scene
coverage, alpha textures, dynamic vehicles, performance or a screenshot fix.
Hybrid minimum visibility cannot brighten incorrectly dark native shadows.
Headlights, clustered local lights and ambient illumination remain unchanged.

Receiver-position rejection is **not** a general frame-age check: an old mask
at the same receiver can match. The relay has no frame or sunlight-direction
generation key. Solving that requires a verified integration contract.

The existing bias intentionally ignores a face 0.06 units above the receiver
when normal and ray align, but accepts one 0.2 units above. That documents a
contact-shadow limitation; bias was not tuned without a game comparison.
Next live gate is one separately agreed sunlight test when the user returns.
