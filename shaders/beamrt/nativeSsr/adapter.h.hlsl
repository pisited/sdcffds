#ifndef BEAMRT_SSSR_FORK_ADAPTER
#define BEAMRT_SSSR_FORK_ADAPTER

// BeamRT-owned adapter for the locally forked MIT traversal core. Pixel-plane
// traversal only: no private native targets, water receivers or native object.
// Per-invocation static values are compiler-local registers, not shared UAVs.
static float3 beamrtSssrEyeRay = 0.0;
static float3 beamrtSssrDu = 0.0;
static float3 beamrtSssrDv = 0.0;
static float2 beamrtSssrUv = 0.0;
static bool beamrtSssrReverse = false;
static bool beamrtSssrInvalidGeometry = false;
float2 beamrtSssrSelect(bool2 c, float2 a, float2 b)
{ return float2(c.x ? a.x : b.x, c.y ? a.y : b.y); }
float3 beamrtSssrSelect(bool3 c, float3 a, float3 b)
{ return float3(c.x ? a.x : b.x, c.y ? a.y : b.y, c.z ? a.z : b.z); }
float beamrtSssrForwardDepth(float rawDepth)
{ return beamrtSssrReverse ? 1.0 - rawDepth : rawDepth; }
float beamrtSssrRawDepth(float forwardDepth)
{ return beamrtSssrReverse ? 1.0 - forwardDepth : forwardDepth; }
bool beamrtSssrFinite(float4 value)
{ return all((asuint(value) & 0x7f800000u) != 0x7f800000u); }
float FFX_SSSR_LoadDepth(int2 pixel, int mip)
{
    uint w, h;
    prepassDepthTexTex.GetDimensions(w, h);
    if (mip != 0 || any(pixel < 0) || any(pixel >= int2(w, h)))
    { beamrtSssrInvalidGeometry = true; return 1.0; }
    float rawDepth = prepassDepthTexTex.Load(int3(pixel, 0)).r;
    if (!beamrtSssrFinite(rawDepth.xxxx) || rawDepth < 0.0 || rawDepth > 1.0)
    { beamrtSssrInvalidGeometry = true; return 1.0; }
    return beamrtSssrForwardDepth(rawDepth);
}
float3 FFX_SSSR_LoadWorldSpaceNormal(int2 pixel)
{
    float2 encoded = prepassTexTex.Load(int3(pixel, 0)).xy;
    if (!beamrtSssrFinite(float4(encoded, 0, 0)) || any(encoded < 0) || any(encoded > 1))
    { beamrtSssrInvalidGeometry = true; return float3(0, 0, 1); }
    return decodeNormalXY(encoded);
}
float3 FFX_SSSR_ScreenSpaceToViewSpace(float3 position)
{
    // Camera-relative world coordinates instead of view coordinates: distances
    // are invariant under the omitted camera rotation. No absolute-world matrix
    // convention or floating-origin translation is guessed by this adapter.
    float eyeDepth = realToEyeLinearDepth(ndcToRealDepth(
        beamrtSssrRawDepth(position.z), projParams.zw), projParams);
    return (beamrtSssrEyeRay + beamrtSssrDu * (position.x - beamrtSssrUv.x)
        + beamrtSssrDv * (position.y - beamrtSssrUv.y)) * eyeDepth;
}
#include "ffx_sssr_fork.h.hlsl"

bool beamrtSssrForkTrace(PFXVertToPix input, float3 du, float3 dv,
    float3 rayOrigin, float3 rayDirection, float minTravel, float maxTravel,
    uint lookupBudget, float thickness, out float2 hitUv, out float rayEyeDepth,
    out float sceneEyeDepth, out float hitTravel, out float nativeConfidence,
    out int failureReason)
{
    // Same numeric reason IDs as the trace diagnostic; independent of macros.
    // 1 budget, 2 view, 13 invalid input, 14 finite segment, 15 native validation.
    failureReason = 13;
    hitUv = 0.0; rayEyeDepth = 0.0; sceneEyeDepth = 0.0;
    hitTravel = 0.0; nativeConfidence = 0.0;
    uint w = 0, h = 0, nw = 0, nh = 0;
    prepassDepthTexTex.GetDimensions(w, h);
    prepassTexTex.GetDimensions(nw, nh);
    if (w == 0 || h == 0 || nw != w || nh != h) return false;
    if (!beamrtSssrFinite(float4(rayOrigin, minTravel))
        || !beamrtSssrFinite(float4(rayDirection, maxTravel))
        || maxTravel <= minTravel || thickness <= 0.0) return false;
    beamrtSssrEyeRay = input.wsEyeRay; beamrtSssrDu = du; beamrtSssrDv = dv;
    beamrtSssrUv = input.uv0;
    beamrtSssrInvalidGeometry = false;
    beamrtSssrReverse = realToDepthNDC(projParams.x, projParams)
        > realToDepthNDC(projParams.y, projParams);
    float2 startUv = 0.0, endUv = 0.0;
    float startDepth = 0.0, endDepth = 0.0;
    if (!beamrtProjectEyeVector(rayOrigin + rayDirection * minTravel - eyePosWorld,
        input.wsEyeRay, du, dv, input.uv0, startUv, startDepth)
        || !beamrtProjectEyeVector(rayOrigin + rayDirection * maxTravel - eyePosWorld,
        input.wsEyeRay, du, dv, input.uv0, endUv, endDepth)) return false;
    float3 start = float3(startUv, beamrtSssrForwardDepth(realToDepthNDC(startDepth * projParams.y, projParams)));
    float3 end = float3(endUv, beamrtSssrForwardDepth(realToDepthNDC(endDepth * projParams.y, projParams)));
    float3 direction = end - start;
    if (!beamrtSssrFinite(float4(start, 0)) || !beamrtSssrFinite(float4(end, 0))
        || any(start.xy < 0.0) || any(start.xy >= 1.0)
        || all(abs(direction.xy) * float2(w, h) < 0.001)) return false;
    // Explicit mip-0 dispatcher: the native pixel-step functions are reused,
    // but no private Hi-Z hierarchy or indirect/wave dispatcher is assumed.
    float3 inverseDirection = beamrtSssrSelect(direction != 0.0, 1.0 / direction,
        float3(FFX_SSSR_FLOAT_MAX, FFX_SSSR_FLOAT_MAX, FFX_SSSR_FLOAT_MAX));
    float2 floorOffset = beamrtSssrSelect(direction.xy < 0.0, float2(0, 0), float2(1, 1));
    float2 uvOffset = beamrtSssrSelect(direction.xy < 0.0, -0.005 / float2(w, h), 0.005 / float2(w, h));
    float3 hit = start;
    float screenTravel = 0.0;
    FFX_SSSR_InitialAdvanceRay(start, direction, inverseDirection, float2(w, h),
        1.0 / float2(w, h), floorOffset, uvOffset, hit, screenTravel);
    bool valid = false;
    uint remaining = clamp(lookupBudget, 5u, 2048u);
    failureReason = 1;
    [loop] for (uint step = 0; step < 2048u; ++step)
    {
        if (remaining == 0) break;
        if (!beamrtSssrFinite(float4(hit, screenTravel))) { failureReason = 13; break; }
        if (screenTravel < 0.0 || screenTravel > 1.0) { failureReason = 14; break; }
        if (any(hit.xy < 0.0) || any(hit.xy >= 1.0) || hit.z < 0.0 || hit.z > 1.0)
        { failureReason = 2; break; }
        float depth = FFX_SSSR_LoadDepth(int2(hit.xy * float2(w, h)), 0);
        if (beamrtSssrInvalidGeometry) { failureReason = 13; break; }
        uint cost = FFX_SSSR_IsSkyDepth(depth) ? 1u : 5u;
        if (remaining < cost) break;
        remaining -= cost;
        if (FFX_SSSR_IntersectPixel(start, direction, inverseDirection, float2(w, h),
            floorOffset, uvOffset, depth, hit, screenTravel)) { valid = true; break; }
        if (beamrtSssrInvalidGeometry) { failureReason = 13; break; }
    }
    // The core traverses an infinite projected line. The adapter owns a finite
    // frustum-clipped world segment; budget exhaustion is never a hit or sky.
    if (!valid || beamrtSssrInvalidGeometry || !beamrtSssrFinite(float4(hit, screenTravel))
        || screenTravel < 0.0 || screenTravel > 1.00001
        || any(hit.xy < 0.0) || any(hit.xy >= 1.0) || hit.z < 0.0 || hit.z > 1.0) return false;
    failureReason = 14;
    float3 hitRelative = FFX_SSSR_ScreenSpaceToViewSpace(hit);
    hitTravel = dot(hitRelative - (rayOrigin - eyePosWorld), rayDirection);
    if (!beamrtSssrFinite(float4(hitRelative, hitTravel))
        || hitTravel < minTravel - 0.002 || hitTravel > maxTravel + 0.002) return false;
    float3 expectedRelative = rayOrigin - eyePosWorld + rayDirection * hitTravel;
    if (length(hitRelative - expectedRelative) > max(0.002, thickness)) return false;
    // Native validation rejects near-receiver/back-facing/sky hits. Its
    // confidence is retained, not converted into a claim of material ownership.
    nativeConfidence = FFX_SSSR_ValidateHit(hit, input.uv0, rayDirection, float2(w, h), thickness);
    failureReason = beamrtSssrInvalidGeometry || !beamrtSssrFinite(nativeConfidence.xxxx) ? 13 : 15;
    if (beamrtSssrInvalidGeometry || !beamrtSssrFinite(nativeConfidence.xxxx) || nativeConfidence <= 0.0) return false;
    hitUv = hit.xy;
    rayEyeDepth = realToEyeLinearDepth(ndcToRealDepth(beamrtSssrRawDepth(hit.z), projParams.zw), projParams);
    // The core hit is evaluated on its discontinuity-aware pixel plane, not
    // quantized back to a different depth at that pixel's center.
    sceneEyeDepth = rayEyeDepth;
    failureReason = 12;
    return true;
}
#endif
