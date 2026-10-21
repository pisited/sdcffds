# Co-linked private-type isolation: offline repair

This repairs a confirmed linkage defect, not a demonstrated in-game recovery.
No BeamNG launch, attach, deployment, hot unload, native GI dispatch or lighting
change was made during this repair. The previously crashed candidate remains
blocked; any new game test needs a separate frozen review and approval.

**2026-10-15 update:** a separately reviewed and approved observation-only startup
of the repaired candidate captured the GI draw and closed normally (host/game
exit 0). Resource metadata still refused at object capacity. See the
[exact-build live result](TYPE_ISOLATION_LIVE_OBSERVATION.md); the offline repair
history below is preserved and the general deployment hold remains.

## Defect and repair

The crashed bootstrap linked incompatible global `Context` definitions from
`gi_bindings.cpp` and `resource_tracker.cpp`. Their constructor symbols and
`unique_ptr<Context>` specializations had the same external identity. Binary
inspection of the exact crashed DLL showed both start paths calling the binding
constructor despite different allocation sizes and layouts. The binding layout
writes an unordered-set mask of 7 over a resource-table shared-pointer control
block. The owned game dump's shared-pointer decrement fault wrote to address
0xf, consistent with that corruption. See the preserved crash investigation in
`live-first-failure-2f2f352f6c0c45b4828f8934f1a8cd82/RESULT.md` under
`.beamrt-validation/`.

Implementation types now have translation-unit-local identity through anonymous
namespaces in the binding observer, resource tracker and creation audit. This
also separates their three different `Slot` types and other private helpers.
Public headers, SDK slot declarations and exported C API definitions remain
global. No public ABI, capacity, overlap guard, lifetime rule or proof flag changed.

The strict production build now saves a linker map. In the repaired candidate:

- Binding `Context`: private discriminator `624826d0`, constructor RVA `0x10ce0`.
- Resource `Context`: private discriminator `0666bbaa`, constructor RVA `0x1dac0`.
- Audit `Slot`: separate discriminator `d6c96fae`; binding/resource `Slot` names
  use their own component discriminators.

The different-layout constructors have distinct names and addresses. No global
`Context`/`Slot` constructor or destructor remains in the inspected map. Identical
small template bodies may still be legitimately folded; this check does not
require every emitted function to have a distinct address.

## Co-linked regression and its negative control

The new disposable `resource-objects` case uses the actual production bootstrap,
with all three implementations linked together. It verifies exactly nine live
resources before pressure: six textures, constants, target and readback; uploads
have already retired. It retains further allocations and requires an exact
one-resource increment after each allocation through 128, passing slot 58 while
healthy. Native allocation 129 must succeed, while metadata fails closed once
with ObjectCapacity / Committed / limit 128 / attempted 129, pressure 1 and no
overlap. The first-failure bytes must survive the draw receipt and OFF unchanged.
Native GPU output remains 23 before and after OFF, with all ten native slots
restored. The parent compares the published resource receipt with the child's
exported receipt and requires the owned process/job to finish normally.

The initial relative-count version was insufficient: the old DLL passed WARP
once. Its startup receipt already counted a phantom live resource before any
fixture resources were created. Requiring the exact known baseline prevents
normalizing the test against such corruption. Do not cite the earlier WARP pass
as evidence against the binary defect or as a successful negative control.

With the final fixture and the exact old crashed DLL, both the RTX and WARP
negative runs failed: the retained disposable child handles reported
`0xc0000005`. These runs selected only the fixture executable, not BeamNG. The
exception code alone does not establish the identical fault instruction or
complete ownership chain from the game dump. The repaired DLL passes the same
fixture on both backends.

## Verification and frozen evidence

- `tools/test.ps1`: **266/266**, including ten new private-type/linkage guards.
- Strict standalone resource fixtures: five sessions each on RTX 4070 and WARP,
  **17/17** groups per session, with existing malformed-receipt and OFF checks.
- Fresh strict production startup: **134** rejected option/payload cases,
  **11** binding/thread cases and **11** resource-connected cases, all passed.
- Separate CI-style WARP-only resource matrix: **9/9**, all private jobs drained.
- Native sources were frozen before the final build and checked afterward.
  The D3D12 debug layer was unavailable; these are not debug-layer-clean results.

Under `.beamrt-validation/`:

- `native-startup-resource-022288f526bb423ca5e2084714205346`: final candidate,
  linker map, frozen native sources and disposable positive-test receipts.
- `type-isolation-final-ed0a9cd44b1c40599b69716436fd8202`: final build log,
  source hashes, symbol verification, project suite and CI-style WARP repeat.
- `resource-tracker-4e1e4e90a00f44dbb3f88b9894604963`: standalone sources,
  strict build and five-session logs for both backends.
- `native-startup-resource-af0e03dfc4ee441694e194ad8aedb124`: final fixture
  paired with the old DLL solely as an offline negative control, exact input
  hashes and retained child exit receipts. **Never use this bundle for a game test.**
- `native-startup-resource-6495c8a6fbac4b80bb2368910bbd7ca8`: initial weaker
  negative control, including the WARP false pass and RTX access violation.

Final bootstrap SHA-256:
`b13b8051f9fa4d3f8738f19dc547d7146082d62ce8162abd062fa958a610fd82`.
Final host SHA-256:
`8229ae6f291e7e7c0e66585638427adad16e27f4aec5d2ccdf19615427be8341`.
Old crashed bootstrap SHA-256:
`7255cea4294a645058e44c40c58fb6d4af27d8d96e72ba704e6593be8c3cabb0`.

## Remaining boundary

This establishes type isolation and improved offline coverage. It does not
establish game resource coverage, camera meaning, states, synchronization,
GPU completion or native GI consumption. The historical loader anomaly and
unidentified source-reset writer remain unresolved. Keep resource guards and
the general deployment hold intact; review the final frozen candidate before
requesting any separately approved observation-only game test.
