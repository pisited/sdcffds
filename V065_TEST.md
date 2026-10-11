# BeamRT v0.065 first in-game test

Keep the camera fixed for every A/B screenshot.

## 1. Reload and verify

```lua
beamrt_main.disable(); extensions.unload("beamrt_main"); extensions.load("beamrt_main")
print("BeamRT version: " .. tostring(beamrt_main.getVersion()))
beamrt_main.start()
```

Expected: `0.065` and no BeamRT shader/Lua error in `beamng.log`.

## 2. Candidate-continuation A/B

Use the underground fluorescent scene that showed the Linear/DDA difference.

```lua
beamrt_main.setMode("lighting")
beamrt_main.setRayMarcher("screendda")
beamrt_main.setHitValidationStrength(1)
beamrt_main.setCandidateRetryCount(4)
beamrt_main.setCandidateContinuation(0)
```

Capture v0.064-style behavior, then without moving the camera:

```lua
beamrt_main.setCandidateContinuation(1)
```

Capture again. Repeat with:

```lua
beamrt_main.setRayMarcher("linear")
```

The goal is not simply “brighter”. Look for recovered secondary illumination without the old Step Length-dependent duplicate/echo.

## 3. Rejection diagnostic

```lua
beamrt_main.setRayHitDiagnostic("rejection")
```

Compare continuation `0` and `1`. Then exit:

```lua
beamrt_main.setRayHitDiagnostic("off")
```

## 4. Capture Material V2

Do not move the camera while this runs:

```lua
beamrt_main.publishMaterialV2Caches()
```

After a moment:

```lua
dump(beamrt_main.getMaterialCachePublication())
```

The batch captures nine evaluated channels: BaseColor, Opacity, Metallic, Roughness, AmbientOcclusion, NormalsWS, Emissive, ClearCoat and ClearCoatRoughness.

Inspect examples:

```lua
beamrt_main.setMode("bufferdiag")
beamrt_main.setBufferDiagnosticView("raw")
beamrt_main.setBufferDiagnosticGain(1)
beamrt_main.setBufferDiagnosticExposure(0)
beamrt_main.setBufferDiagnostic("roughnessCache", "r")
beamrt_main.setBufferDiagnostic("ambientOcclusionCache", "r")
beamrt_main.setBufferDiagnostic("normalsWSCache", "rgb")
beamrt_main.setBufferDiagnostic("clearCoatCache", "r")
beamrt_main.setBufferDiagnostic("clearCoatRoughnessCache", "r")
beamrt_main.setBufferDiagnostic("opacityCache", "r")
```

## 5. Rebuild clean radiance and inspect emitters

The V2 batch also refreshes BaseColor/Metallic/Emissive with one coherent generation. Keep the camera fixed and run:

```lua
beamrt_main.refreshCleanRadianceDiagnostics()
```

Then inspect:

```lua
beamrt_main.setMode("bufferdiag")
beamrt_main.setBufferDiagnostic("emissiveCache", "rgb")
beamrt_main.setBufferDiagnostic("maskedEmissive", "rgb")
beamrt_main.setBufferDiagnostic("directDiffuseRadiance", "rgb")
beamrt_main.setBufferDiagnostic("emitterClass", "rgb")
```

`emitterClass`: red = native Material_Emissive dominates, green = direct-lit diffuse dominates, yellow = mixed.

For the tunnel fluorescent test, the lamps should be red/yellow if their material really emits; the green tank should be mostly green if it is only reflecting light.

## 6. Emissive-transport A/B

After CleanRadiance is valid:

```lua
beamrt_main.setPTGIRadianceSource("clean")
beamrt_main.setMode("lighting")
beamrt_main.setEmissiveBoost(1)
beamrt_main.setEmissiveSeparation(0)
```

Capture v0.064-style combined weighting, then:

```lua
beamrt_main.setEmissiveSeparation(1)
```

Capture again. This specifically tests whether small real emitters regain influence relative to large directly-lit diffuse surfaces.

## Rollback controls

```lua
beamrt_main.setCandidateContinuation(0)
beamrt_main.setEmissiveSeparation(0)
```

Those two switches restore the two v0.064 behaviors changed by this milestone while keeping the new diagnostics available.
