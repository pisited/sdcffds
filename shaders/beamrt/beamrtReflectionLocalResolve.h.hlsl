#ifndef BEAMRT_REFLECTION_LOCAL_RESOLVE_H_HLSL
#define BEAMRT_REFLECTION_LOCAL_RESOLVE_H_HLSL

#include "beamrtReflectionRadianceSafety.h.hlsl"

bool beamrtReflectionLocalFinite4(float4 value)
{
    return all((asuint(value) & 0x7f800000u) != 0x7f800000u);
}

// Read one coherent receiver tuple using actual input texture dimensions.
// Depth and RT0 share the prepass viewport mapping; F0 has its own RT3 map.
bool beamrtReflectionLocalReceiver(float2 viewUv, out float3 normal,
    out float roughness, out float3 f0, out float depth)
{
    normal = 0.0; roughness = 1.0; f0 = 0.0; depth = 0.0;
    if (any(viewUv < 0.0) || any(viewUv >= 1.0)) return false;
    uint pw, ph, dw, dh, mw, mh;
    prepassTexTex.GetDimensions(pw, ph);
    prepassDepthTexTex.GetDimensions(dw, dh);
    materialSpecTexTex.GetDimensions(mw, mh);
    float2 prepassUv = viewportCoordToRenderTarget(viewUv, rtParams2);
    float2 materialUv = viewportCoordToRenderTarget(viewUv, rtParams3);
    int2 pp = int2(floor(prepassUv * float2(pw, ph)));
    int2 dp = int2(floor(prepassUv * float2(dw, dh)));
    int2 mp = int2(floor(materialUv * float2(mw, mh)));
    if (any(pp < 0) || any(pp >= int2(pw, ph)) || any(dp < 0)
        || any(dp >= int2(dw, dh)) || any(mp < 0) || any(mp >= int2(mw, mh))) return false;
    float4 packed = prepassTexTex.Load(int3(pp, 0));
    float rawDepth = prepassDepthTexTex.Load(int3(dp, 0)).r;
    float3 rawF0 = materialSpecTexTex.Load(int3(mp, 0)).rgb;
    if (!beamrtReflectionLocalFinite4(float4(packed.xyz, rawDepth))
        || !beamrtReflectionRadianceIsFinite(rawF0)) return false;
    float eyeDepth = realToEyeLinearDepth(ndcToRealDepth(rawDepth, projParams.zw), projParams);
    depth = eyeDepth * projParams.y;
    if (!beamrtReflectionRadianceIsFinite(float3(eyeDepth, depth, 0.0))
        || eyeDepth <= 0.0 || eyeDepth >= 0.9999 || depth <= 0.0) return false;
    normal = decodeNormalXY(packed.xy);
    roughness = max(packed.b, 0.02);
    f0 = saturate(rawF0);
    return beamrtReflectionRadianceIsFinite(normal) && dot(normal, normal) > 0.5;
}

// DISPLAY ONLY: one immediate five-tap cross, not a hole-fill pass, temporal
// feedback, ray result, confidence estimator or a new BRDF. Eligible black and
// GGX zero samples have exactly the same geometry weights as bright samples.
float4 beamrtReflectionLocalResolve(PFXVertToPix IN, float4 center)
{
    if (reflectionLocalResolveEnabled <= 0.5 || reflectionLocalResolveStrength <= 0.0
        || reflectionSamplingMode <= 0.5 || reflectionDebugMode > 0.5) return center;
    if (!beamrtReflectionLocalFinite4(center)) return 0.0;
    // No receiver support may be created. Negative grace-frame lifetime and
    // invalid/zero alpha keep their exact bits and are never repaired by RGB.
    if (center.a <= 0.000001) return center;
    if (any(abs(rtParams1.zw) < 0.000001)) return center;
    float2 viewUv = (IN.uv1 - rtParams1.xy) / rtParams1.zw;
    float3 normal, f0;
    float roughness, depth;
    if (!beamrtReflectionLocalReceiver(viewUv, normal, roughness, f0, depth)) return center;
    // Do not smooth polished/mirror detail. Roughness is the sole amplitude
    // ramp: radiance, hit/miss brightness and source confidence never gate taps.
    if (roughness <= 0.08 || roughness >= max(reflectionMaxRoughness, 0.081)) return center;
    if (abs(center.a - depth) / max(depth, 0.0001) >= 0.025) return center;
    uint width, height;
    temporalReflectionTexTex.GetDimensions(width, height);
    float2 imageSize = float2(width, height);
    int2 centerPixel = int2(floor(IN.uv1 * imageSize));
    if (any(centerPixel < 0) || any(centerPixel >= int2(width, height))) return center;
    const int2 offsets[4] = { int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1) };
    // Scaled weights bound the intermediate sum for ordinary finite HDR data.
    float3 total = center.rgb * 0.5;
    float weightSum = 0.5;
    [unroll] for (int tap = 0; tap < 4; ++tap)
    {
        int2 pixel = centerPixel + offsets[tap];
        if (any(pixel < 0) || any(pixel >= int2(width, height))) continue;
        float2 uv = (float2(pixel) + 0.5) / imageSize;
        float2 neighborViewUv = (uv - rtParams1.xy) / rtParams1.zw;
        if (any(neighborViewUv < 0.0) || any(neighborViewUv >= 1.0)) continue;
        float4 neighbor = temporalReflectionTexTex.Load(int3(pixel, 0));
        if (!beamrtReflectionLocalFinite4(neighbor) || neighbor.a <= 0.000001) continue;
        float3 neighborNormal, neighborF0;
        float neighborRoughness, neighborDepth;
        if (!beamrtReflectionLocalReceiver(neighborViewUv, neighborNormal,
            neighborRoughness, neighborF0, neighborDepth)) continue;
        if (abs(neighbor.a - neighborDepth) / max(neighborDepth, 0.0001) >= 0.025) continue;
        float relativeDepth = abs(neighborDepth - depth) / max(depth, 0.0001);
        float depthWeight = 1.0 - smoothstep(0.002, 0.02, relativeDepth);
        float normalWeight = smoothstep(0.97, 0.999, saturate(dot(normal, neighborNormal)));
        float roughnessWeight = 1.0 - smoothstep(0.01, 0.06, abs(neighborRoughness - roughness));
        float f0Weight = 1.0 - smoothstep(0.01, 0.05, length(neighborF0 - f0));
        float weight = 0.125 * depthWeight * normalWeight * roughnessWeight * f0Weight;
        total += neighbor.rgb * weight;
        weightSum += weight;
    }
    float3 filtered = total / weightSum;
    if (!beamrtReflectionRadianceIsFinite(filtered)) return center;
    float amount = saturate(reflectionLocalResolveStrength) * smoothstep(0.08, 0.20, roughness);
    // Return the ORIGINAL alpha, never a filtered depth/lifetime or inferred hit.
    return float4(lerp(center.rgb, filtered, amount), center.a);
}

#endif
