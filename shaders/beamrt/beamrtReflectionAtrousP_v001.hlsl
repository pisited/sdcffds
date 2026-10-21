// BeamRT optional single-step specular variance-guided bilateral filter.
// Input is the existing PLAYABLE temporal reflection; preserve its signed
// receiver depth/lifetime in alpha exactly. Never infer hit status from RGB.
#include "shaders/common/postFx/postFx.h.hlsl"

uniform_sampler2D(inputReflectionTex, 0);
uniform_sampler2D(prepassTex, 1);
uniform_sampler2D(prepassDepthTex, 2);
uniform_sampler2D(reflectionMomentsTex, 3);
uniform_sampler2D(materialSpecTex, 4);

cbuffer perDraw : register(b0)
{
    uniform float reflectionVarianceStrength;
    uniform float reflectionVarianceScale;
    uniform float reflectionMaxRoughness;
#ifdef BEAMRT_REFLECTION_MULTISCALE
    uniform float reflectionAtrousStep;
#endif
    uniform float2 targetSize;
    POSTFX_UNIFORMS
};
#include "shaders/common/postFx/postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float reflectionLuminance(float3 radiance)
{
    return dot(max(radiance, 0.0), float3(0.2126, 0.7152, 0.0722));
}

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float4 center = tex2D(inputReflectionTex, IN.uv0);
    if (!all(isfinite(center))) return 0.0;

    if (reflectionVarianceStrength <= 0.0001 || center.a <= 0.000001)
        return center;

    float4 surface = decodeGBuffer(
        TEX_SAMPLER(prepassDepthTex), TEX_SAMPLER(prepassTex), IN.uv1, projParams);
    float4 packedSurface = tex2D(prepassTex, IN.uv1);
    float roughness = max(packedSurface.b, 0.02);
    if (!all(isfinite(surface)) || !all(isfinite(packedSurface))
        || surface.w <= 0.0 || surface.w >= 0.9999 || roughness >= max(reflectionMaxRoughness, 0.021))
        return center;

    float3 rawF0 = tex2D(materialSpecTex, IN.uv1).rgb;
    if (!all(isfinite(rawF0))) return center;
    float3 F0 = saturate(rawF0);
    float4 moments = tex2D(reflectionMomentsTex, IN.uv0);
    if (!all(isfinite(moments)) || moments.b < 1.0 || moments.a <= 0.0
        || abs(moments.a - surface.w) / max(surface.w, 0.0001) > 0.025)
        return center;
    float historyCount = max(moments.b, 1.0);
    float variance = max(moments.g - moments.r * moments.r, 0.0);
    float centerL = reflectionLuminance(center.rgb);

    // Variance rises where occasional bright GGX samples alternate with dark
    // samples. With short history the moment variance is artificially zero,
    // so allow modest local smoothing rather than pretending high confidence.
    float sigma = max(0.025,
        sqrt(variance + 0.000001) * max(reflectionVarianceScale, 0.25) * 2.0);
    if (historyCount < 4.0)
        sigma = max(sigma, 0.09 + centerL * 0.25);
    float confidence = saturate((historyCount - 1.0) / 8.0);
    float2 texel = 1.0 / max(targetSize, float2(1.0, 1.0));
    float step = 1.0;
#ifdef BEAMRT_REFLECTION_MULTISCALE
    if (!isfinite(reflectionAtrousStep)) return center;
    step = clamp(reflectionAtrousStep, 1.0, 4.0);
    // Geometry/F0 gates do not describe reflected hit layers. Keep the wider
    // scales out of near-polished receivers rather than blurring sharp detail.
    if (step > 1.0 && roughness <= 0.08) return center;
#endif

    float3 total = center.rgb * 4.0;
    float weightSum = 4.0;
    [unroll]
    for (int y = -1; y <= 1; ++y)
    {
        [unroll]
        for (int x = -1; x <= 1; ++x)
        {
            if (x == 0 && y == 0) continue;
            float2 offset = float2((float)x, (float)y) * texel * step;
            float2 uv = IN.uv0 + offset;
            float2 gbufUv = IN.uv1 + offset;
            if (any(uv < 0.0) || any(uv > 1.0)) continue;
            float4 sampleSurface = decodeGBuffer(
                TEX_SAMPLER(prepassDepthTex), TEX_SAMPLER(prepassTex), gbufUv, projParams);
            if (!all(isfinite(sampleSurface)) || sampleSurface.w <= 0.0 || sampleSurface.w >= 0.9999) continue;
            float4 neighbor = tex2Dlod(inputReflectionTex, float4(uv, 0.0, 0.0));
            if (!all(isfinite(neighbor)) || neighbor.a <= 0.000001) continue;
            float4 neighborPacked = tex2Dlod(prepassTex, float4(gbufUv, 0.0, 0.0));
            float3 neighborRawF0 = tex2Dlod(materialSpecTex, float4(gbufUv, 0.0, 0.0)).rgb;
            if (!all(isfinite(neighborPacked)) || !all(isfinite(neighborRawF0))) continue;
            float neighborRough = max(neighborPacked.b, 0.02);
            float3 neighborF0 = saturate(neighborRawF0);
            float relativeDepth = abs(sampleSurface.w - surface.w) / max(surface.w, 0.0001);
#ifdef BEAMRT_REFLECTION_MULTISCALE
            // Do not relax silhouette rejection just because the radius grows.
            if (relativeDepth >= 0.025) continue;
#endif
            float wDepth = exp2(-relativeDepth * 120.0);
            float wNormal = pow(saturate(dot(surface.xyz, sampleSurface.xyz)), 24.0);
            float wRough = 1.0 - smoothstep(0.025, 0.16, abs(neighborRough - roughness));
            float wMaterial = 1.0 - smoothstep(0.04, 0.30, length(neighborF0 - F0));
            float wLuma = exp2(-abs(reflectionLuminance(neighbor.rgb) - centerL) / sigma);
            float wKernel = (x == 0 || y == 0) ? 2.0 : 1.0;
            // Do not treat dark RGB as a miss. Also avoid borrowing radiance
            // from neighbors whose temporal lifetime is invalid.
            float weight = wKernel * wDepth * wNormal * wRough * wMaterial
                * wLuma * (neighbor.a > 0.000001 ? 1.0 : 0.0);
            total += max(neighbor.rgb, 0.0) * weight;
            weightSum += weight;
        }
    }

    float3 filtered = total / max(weightSum, 0.0001);
    float strength = saturate(reflectionVarianceStrength) * lerp(0.65, 1.0, confidence);
#ifdef BEAMRT_REFLECTION_MULTISCALE
    if (step > 1.0) strength *= smoothstep(0.08, 0.20, roughness);
#endif
    return float4(max(lerp(center.rgb, filtered, strength), 0.0), center.a);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
