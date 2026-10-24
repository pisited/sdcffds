# One-bounce geometric hit mask - revision 11

Revision 12 adds a separate [frozen main-camera variant](vehicle-camera-reflection-mask.md)
without changing this fixed-view baseline. The revision 11 live run succeeded:
118 A-to-B and 137 B-to-A hits, all 255 removed by source exclusion, with all
192 receiver self-hits preserved and eight bounce packets matching full scans.

This is an **ideal-mirror CPU geometry diagnostic**, not material shading,
hardware RT integration, gameplay-camera rendering or an off-screen reflection
acceptance result. Identity/depth and isolated-normal snapshots remain available.

## Run

Keep exactly two parked cars a few metres apart side-by-side, enter one and
pause physics with J. Keep exporter/other mesh-readback tools idle. Run once in
**GE Lua** (a fresh capture is required because earlier jobs freed their BVHs):

```lua
extensions.reload('beamrt_vehiclePairProbe'); local ok,why=extensions.beamrt_vehiclePairProbe.startReflectionMaskTest(); print(tostring(ok)..': '..tostring(why))
```

Close the console to see the progress panel. Keep physics/vehicles unchanged;
camera movement alone is fine. Status uses the same command:

```lua
print(jsonEncode(extensions.beamrt_vehiclePairProbe.getImageStatus()))
```

After acquisition, build, original reference checks and rendering, an additional
`checking-bounces` stage compares sampled reflected queries against full scans.
The 180-second whole-job timeout, pause/identity/pose/prop/material guards and
cleanup rules remain active. Do not reset either car while collecting results.

## Four panels

Each panel is 96x64, for one 192x128 image (24576 output pixels). Columns are
receiver A on the left and receiver B on the right:

- Top: nearest one-bounce hit with BOTH captured cars present in the secondary scene.
- Bottom: exactly the same primary hit/reflected ray, with the OTHER car excluded
  from the secondary CPU query. Nothing is hidden/removed in the game.

Colors:

- Green: reflected ray's nearest hit is the other car.
- Orange: reflected ray hit the receiver itself.
- Slate gray: primary receiver hit, but reflected ray missed captured geometry.
- Dark background: primary ray missed the receiver.

Green top-row regions should lose their green in the corresponding bottom row.
Bottom pixels may become gray OR orange: farther receiver geometry is still
present and must not be deleted to manufacture a miss. No target silhouette or
hit is fabricated when the surface directions do not reflect toward the source.

The primary views look horizontally toward each car's inward-facing side, using
the captured pair's horizontal separation. Each primary view isolates its receiver
and fits that receiver's geometry bounds. **This is not proof that a real camera
can see that surface**, or that another object does not block the primary view.

## Geometry and numerical policy

Every receiver triangle is treated as an ideal geometric mirror, regardless of
its actual paint, glass, light/lens, interior or cutout material. Opacity, BRDF,
Fresnel, roughness, textures, environment lighting and radiance are not evaluated.
Only the two captured vehicles exist in this diagnostic scene.

For primary direction D and unit world geometric face normal N, the reflected
direction is `R = D - 2*dot(D,N)*N`. Reversing N does not change R. Normals come
from transformed triangle positions, not native normal/color streams. Winding
and physical material behavior remain unverified.

The secondary origin is the primary hit point plus 0.01 m along R. The existing
segment kernel also excludes hits within 0.08 m of either segment endpoint.
Consequently very near receiver layers can be skipped; this is not verified
thin-layer/contact visibility. The far length covers the combined geometry's
diagonal plus 2 m, capped by a refusal above the supported 1000 m segment limit.
The receiver is retained in BOTH full and source-excluded secondary queries.

## Acceptance fields and limits

`profile="bounce"` identifies this mode. `acceleratorMatchesReference=true`
still requires the original four direct geometry controls to match full scans.
The mask then checks up to eight bounce packets (two generic plus two positive
inter-car samples per receiver), each with full-pair and source-excluded linear
scans. Those scans use copied world triangles directly and do not consult BVH
boxes/order/topology. Matching includes hit/miss, vehicle, original triangle
reference and distance. It is sampled validation, not proof for all rays.

- `otherHitsA` / `otherHitsB`: A-to-B / B-to-A positive geometric bounce samples.
- `selfHits` / `reflectedMisses`: full secondary queries which self-hit/miss.
- `changedPixels`: positive source hits removed by the exclusion control.
- `reflectedReferenceMatched`: all selected reflected comparisons matched.
- `bounceReferenceTriangleTests`: full-scan cost, separate from BVH tests and the
  original direct reference controls.
- `sourceExcludedControlPassed`: at least one positive inter-car hit existed,
  and all positives lost that source hit in the exclusion query.
- `oneBounceGeometricControlsPassed`: positives in BOTH directions, exclusion
  passed, and reflected reference comparisons matched.

`phase="complete"` alone means computation finished, not that the mirror setup
produced inter-car hits. Legitimate all-miss setups remain complete with the pass
fields false. Disagreement with a full scan rejects publication of the image.
`offscreenReflectionTestPassed`, `gpuExecutionVerified`, `materialShadingVerified`
and `opaqueVisibilityVerified` remain false even when geometric controls pass.

Bulk BVH limits and cooperative work budget are unchanged. At most 12288 primary
samples and two secondary queries per primary hit run, plus bounded comparisons.
The output is saved as `/settings/beamrtVehicleRayImage-bounce-<run>.bmp` and shown
for 120 seconds; `getImageStatus().file` gives the exact path. Old images are kept.
Only pixel masks are exported, never raw vertex/index arrays. All source/BVH
buffers are dropped on completion/cancel as in earlier image modes.

Offline tests cover analytic reflection angles and normal-sign invariance,
known opposite-plane hits/exclusions, preserved receiver blockers, legitimate
all-miss setups, rejection of fabricated answers, full-scan independence,
four-panel correspondence, cooperative cancellation and native lifecycle/export.
The validation fixture uses synthetic geometry, not BeamNG vehicles. The live
revision 11 evidence above concerns the geometric mask only, not shaded output.
