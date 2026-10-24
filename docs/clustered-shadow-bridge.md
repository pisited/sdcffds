# Clustered shadow bridge: captured contract, not a live integration

Evidence date: 2026-10-23. Source is the saved BeamNG D3D12 night capture,
not upstream Torque3D defaults. No game launch, native DLL insertion, shader
replacement, sandbox change or beauty/GI attenuation is performed here.

## Exact pass identity

The confirmed compute shader is capture resource 45967, created inline by
pipeline 45966 using root signature 935. Its recorded Dispatch is chunk 22698
on command list 68142, with groups 320x172x1. This matches the earlier inspected
lighting event 22811 through shader identity and the same camera/light/view
bindings, not dimensions alone. Capture IDs are never runtime identifiers.

Pinned original blobs, recovered on CPU from capture serialization:

| Blob | Bytes | SHA-256 |
| --- | --- | --- |
| Compute shader | 24644 | 8ec9ab0a1345cd9fe0a4472590d30360353fb9879966f5e7b8ef6f97f33b0693 |
| Root signature | 308 | cf1601a54a0b5ef72cce59b35748d18d456323f65dfdfcd07fc19fb411856ee7 |

`native/capture/root_layout_inspect.cpp` uses the public Windows SDK
D3D12CreateVersionedRootSignatureDeserializer. The captured blob decodes as
version 1.0, flags zero, no static samplers, all parameters ALL-visible. The
inspector creates no D3D12 device or GPU work and rejects a malformed control.
It is separate from the strict three-parameter legacy GI root decoder, which
must not be loosened to admit this different pass.

## Root layout and captured arguments

All registers are in space zero.

| Root parameter | Binding | Captured role |
| --- | --- | --- |
| 0 | Direct CBV b0 | bufferdata: resource 47072, offset 129838080, reflected size 272 |
| 1 | Direct SRV t2 | clusterGrid: resource 674, offset 0 |
| 2 | Direct SRV t3 | clusterLightIndices: resource 675, offset 0 |
| 3 | Direct SRV t4 | clusterLights: resource 68776, offset 0 |
| 4 | Direct SRV t15 | shadowViews: resource 70698, offset 0 |
| 5 | Texture SRV table | t0-t1 at table offset 0; t6-t14 at table offset 6 |
| 6 | UAV table | u0 at table offset 0: lightinfoOut |
| 7 | Sampler table | s0-s1 at table offset 0 |

The light/view buffers are observed in actual recorded
SetComputeRootShaderResourceView calls. They are not ordinary named textures,
nor descriptors in parameter 5's texture table. The atlas is t14 at table
offset 14, not its shader reflection-list index 13. Table offsets 2-5 are gaps;
do not compact or renumber them. The output is a UAV, not an OM render target.

This is a definite mismatch with existing prototypes:

- The startup GI binding observer and its SDK slots are graphics-draw-specific.
  The accepted old GI root has three parameters, unlike this eight-parameter root.
- The standalone native capture prototype supports compute pass identities,
  but its input contract only admits one SRV descriptor table. It does not hook
  SetComputeRootShaderResourceView or expose direct root-SRV resource inputs.
  Root CBV/UAV address metadata is not equivalent to these missing root SRVs.
- The old legacy point/spot CustomMaterial swap cannot establish observation of
  this different compute pipeline. Keep its clustered-backend refusal in place.

`tools/beamrt_cluster_compute_contract.py` validates the SDK layout, pinned blob
lengths/hashes, recorded inline shader/PSO/root identity, direct root buffers and
camera CBV against the earlier dispatch reflection/binding report. It refuses
changed binaries, shifted registers/table offsets, ambiguous pipeline matches,
table bindings substituted for root SRVs, and wrong resource/CBV offsets.

The generated `cluster-compute-bridge-manifest.json` is an OFFLINE evidence
manifest. It retains runtimeBindingEstablished=false, safeAttachEstablished=false
and gpuOrderingVerified=false. It is not a loader input that activates a hook.

## Why the data matters

Recorded uploads contain 186 light records and twelve one-view spotlights.
Their matrices and atlas rectangles are consistent with true light-space
projection. Four mapped lights have fractional shadowStrength, and 174 uploaded
records have no assigned shadow view in this snapshot. Those are observations,
not proof of why a particular light was omitted or why the user's shadows fade.
Native finite map allocation/fading can be view-dependent without using SSR.

Camera depth remains useful to reconstruct the receiving surface; the native
occluder data comes from the separate light-space atlas. Reconstructing a
receiver from camera depth does not turn an atlas lookup into screen-space
occluder tracing. The existing BeamRT depth-ray sandbox remains screen-space;
these findings do not retroactively give it off-screen geometry coverage.

## Next implementation boundary

1. Build a separate default-off, read-only COMPUTE binding fixture against this
   exact contract, including direct root SRVs and UAV output provenance. Do not
   relabel the existing graphics observer or force it to accept another ABI.
2. Resolve observed GPU buffer addresses through same-device live resource
   provenance/generations; never inject capture IDs or assume a descriptor
   heap contains the direct light/view bindings. Tie upload ranges to submission.
3. Establish per-frame/view freshness, resource lifetime, complete state/queue
   ordering and final-consumer fence retirement before accessing live contents.
   CPU recording order and matching bytecode alone do not establish those gates.
4. Export one selected light's visibility to an owned diagnostic target with
   receiver/light/frame/view identity. Verify actual atlas pixels and an
   off-screen caster. Missing data remains unknown, not fabricated full light.
5. Only then consider beauty/GI consumption. Native direct lighting already
   applies its shadow once; do not multiply the final image by another copy.

A supported BeamNG engine export would be preferable, but no suitable Lua
buffer/atlas export was identified in the inspected namespace/scripts. A live
native observation needs a separately reviewed exact-binary launch, startup
and rollback contract. No existing-process attach or new game-native deployment
is implied by this offline pass inspection.
