# PostFX shader compilation audit — 2026-10-13

Follow-up: [GI/reflection history audit](native/lighting/README.md) reproduces
HDR moments clipping and invalid-data contamination, repairs their shaders/
formats, and raises validation to 221 tests plus 35 GPU cases per backend.

Performed directly in the installed unpacked BeamRT folder. BeamNG stayed
closed. No native host/DLL rebuild, deployment, settings change or shader-cache
deletion occurred.

## Confirmed shader defect and repair

`shaders/beamrt/beamrtMomentsP_v001.hlsl` had a reflection-moments example
appended after its vertex entry, as executable global declarations. It referred
to `currentReflectionTex`, `IN`, `previousMoments` and `alpha`, which are not
bindings or variables in this GI shader. Strict pixel compilation failed with
`X3004: undeclared identifier 'currentReflectionTexTex'` and produced no code.

The example is now preserved in a block comment. The existing executable GI
moment calculation, history policy, texture slots and constants are unchanged.
Both vertex and pixel stages now compile. The main Lua renderer creates this
moments pass in its GI chain and binds the copied moments history to the
six-input temporal shader, which reads its alpha for historical depth. This
is not just an unused standalone worker shader.

## Verification

- Baseline failure and source copy retained under ignored
  `.beamrt-validation/postfx-shader-audit-a9d44bf7629c409d8ce7900e6bc0609a`.
- `tools/tests/validate_postfx_shaders.py` discovered 24 unique literal shader
  paths in `lua/ge/extensions/beamrt/main.lua`. All 48 VS/PS entries compiled
  with installed BeamNG headers and FXC `/Ges /WX /O3`, shader model 5.
- Compiler results and logs retained under ignored
  `.beamrt-validation/postfx-compile-3885515ff1ca46d2a283a386d97d8a94`.
- `tools/test.ps1`: 211/211 Python/Lua/source tests passed.
- Repaired moments source SHA256:
  `ef1fa3951dd4b4b518d9fcfb9d6479c6d7501e57ebbcb74d882cc3cbf06cd6f4`.

## Boundary

Compilation does not demonstrate actual game execution, engine shader-cache
refresh, SM6 compatibility, complete shader/permutation coverage, or visual
improvement. This run covers the literal main-renderer references, not every
optional extension, historical shader version or native lighting permutation.
No claim that this defect caused the reported shadows, orange leakage or
flicker: the running game may have used a different cached artifact. Those
symptoms still need an appropriately bounded live test when the user returns.

The earlier shared-BVH repairs and native startup investigation remain separate.
This repair does not connect clustered headlights or enable native GI.
