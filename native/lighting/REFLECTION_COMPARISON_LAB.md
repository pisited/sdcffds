# Reflection comparison lab (0.114)

Opt-in exaggeration for identifying missing coverage, filtering softness, and
understated contribution. These are temporary comparisons, **not additional
quality presets**. Performance, Balanced, Quality and Cinematic are unchanged.
The normal GI/lighting tuning and the installed game files are not modified.

The owned fork still combines native-derived mip-0 traversal with BeamRT's
GGX, source reconstruction, temporal filter, and additive composition. It is
not the integrated native SSR pipeline. Native's separate surface histories,
reprojection, variance/sample-count data and receiver-aware filtering are
important remaining integration work, not features obtained by copying the
traversal. Higher brightness is not evidence of more accurate reflections.

## Controls

Reload the extension, keep integrated native SSR **off**, and explicitly enable
the BeamRT fork. Open **Reflection comparison lab** in the tuner.

| Comparison | Deliberate difference |
| --- | --- |
| Normal | Remove all lab overrides; use the current ordinary tuning. |
| More coverage | Fork only: 2,048 traversal-depth lookup budget, 64 m physical reach, roughness eligibility at least 0.65. |
| Raw | Same extended coverage; no source filter, spatial resolve, variance display filter or history accumulation. The sample sequence still advances. |
| 8x punch | Same extended coverage; multiply the final reflected contribution by eight. Base beauty and history values are not multiplied. |
| Settled | Same extended coverage; bounded 0.04 current-frame weight at 60 Hz, 0.65 spatial-denoise setting. Motion rejection remains on. |

The coverage experiment changes several knobs together to expose headroom; it
does **not** isolate which of reach, work budget or receiver cutoff helped.
Raw/8x/Settled share those coverage overrides so their reconstruction/brightness
differences can then be compared against More coverage. Native water capture,
off-screen visibility and Hi-Z are not added. More work may cause severe
frame-time spikes; the maximum remains finite even in this experiment.

Gain/filter comparisons also work with **Use experimental tracer**. Its existing
trace geometry limits and roughness eligibility remain unchanged, so that
backend switch is not an algorithm-only benchmark with matched coverage.
Changing the lab profile does not enable a renderer, change GI mode, select a
backend, or touch native settings. **Normal** restores effective ordinary
uniforms; no backup/restore of saved user values is necessary because those
values were never edited. Reload starts at Normal. Source/convergence captures
suspend lab overrides; active diagnostics/audits block profile changes.

Settled uses an explicit lab-only temporal override because the production
playable reconstruction floors its 60-Hz weight at 0.10. Merely setting the
existing blend slider to 0.04 would not test the intended longer EMA. The lab
weight is bounded to [1/64, 1]; geometry, receiver/motion validity and valid-zero
sample handling remain intact. Longer accumulation can cause trailing and
softness; it is not a verified native denoiser replacement.

## Reading failures

Use **Reflection diagnostics -> Rejection** with the fork selected. The
previous adapter returned undifferentiated zero on many failed rays. It now
propagates a reason without changing production miss radiance/visibility:

- Magenta: traversal work exhausted.
- Purple: left the view.
- Teal: reached/exceeded the finite physical segment or inconsistent hit position.
- Yellow: invalid input/geometry or nonfinite evidence.
- Lavender: native-derived hit validation rejected the candidate.
- Cyan: inherited receiver/front-sample gate rejected it.
- Red/brown/white: inherited thickness/backface/minimum screen-travel rejection.
- Green: accepted geometry; this does not require a bright source.
- Grey/dark grey: ineligible receiver or below-macrosurface GGX direction.

Validity groups rejected native-validation candidates in red and unresolved
adapter misses in magenta. Raw source colour remains independent of confidence;
the contribution view shows the weighted production term. No confidence floor,
accept-invalid fallback or brightness-based validity was added.

Reflection audit manifests now record the selected backend and lab policy per
stage, plus CPU binding/request status. These receipts are not GPU completion
proof. The audit freezes one GGX sample and disables temporal denoising; it is a
coverage/source/composition test, not a measure of settled noise quality. Its
historical `01-native` filename means **BeamRT disabled**, not integrated SSR
enabled. A true native comparison needs a separate same-camera run.

## Verification boundary

The offline fixture executes production fork, compositor and temporal shaders.
It checks normal-versus-prior composition/history equality, display-only gain,
miss preservation, classified failures, extended reach, valid black/invalid
sources, both depth conventions, and the real lab EMA. Its far-plane-dependent
vertex producer shares the production constant layout; fixed eye-ray lengths
cannot silently invalidate the scaled-distance test.

Offline passes do not certify game scheduling, performance, perceived sharpness,
native parity or water support. The new lab still needs an actual game A/B.

Verified on 2026-10-20: **37/37** synthetic checks on RTX 4070 and WARP;
the scaled distant-wall receiver recovered **58 -> 168** hits on RTX and
**72 -> 182** on WARP, in both depth conventions. Normal compositor/temporal
outputs matched v034/v039 exactly in their reference cases. These are not
game-wide hit-rate or image-quality measurements. The D3D12 debug layer was
unavailable. Strict FXC compiled **52/52** production vertex/pixel entries;
Python/Lua discovery ran **1,016 tests: 1,009 passed, 7 skipped**. Mod traversal
passed with no exclusions. No game process was controlled or reloaded.
