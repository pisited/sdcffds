// OFFLINE helper experiment. Native includes provide real normal/surface
// packing, radiance sanitation and denoiser constants; no stock source copied.
#include "shaders/common/gbuffer.hlsl"
#include "shaders/common/postFx/sssr/surface.hlsl"
// Installed native SM6 uses select(). This fixture's SM5 pixel host needs
// only its equivalent componentwise bool3 overload; production is untouched.
float3 select(bool3 condition, float3 yes, float3 no)
{
    return float3(condition.x ? yes.x : no.x, condition.y ? yes.y : no.y,
        condition.z ? yes.z : no.z);
}
#include "shaders/common/postFx/sssr/radiance.hlsl"
#include "shaders/common/postFx/sssr/include/ffx_denoiser_reflections_config.h"
#include "shaders/beamrt/beamrtNativeSsrHistory.h.hlsl"
Texture2D<float4> fixtureRadiance : register(t0);
Texture2D<float4> fixtureNormalClass : register(t1);
Texture2D<float4> fixtureDepthMask : register(t2);
cbuffer perDraw : register(b0)
{
    float3 currentNormal;
    float currentDepth;
    float currentClass;
    float2 phase;
    float fixtureMode;
    float fixtureDecodeNative;
    float fixtureMinimumConfidence;
};
struct Vertex { float4 position : SV_Position; };
Vertex mainV(uint index : SV_VertexID)
{
    Vertex output;
    float2 uv = float2((index << 1) & 2, index & 2);
    output.position = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return output;
}
float4 mainP(Vertex input) : SV_Target0
{
    BeamRTNativeHistoryTap taps[4];
    float4 baseline = 0.0;
    float3 baselineNormal = 0.0;
    float baselineDepth = 0.0;
    [unroll] for (int index = 0; index < 4; ++index)
    {
        float4 rawNormalClass = fixtureNormalClass.Load(int3(index, 0, 0));
        float4 depthMask = fixtureDepthMask.Load(int3(index, 0, 0));
        taps[index].normalWS = rawNormalClass.xyz;
        taps[index].receiverClass = rawNormalClass.w;
        taps[index].linearDepth = depthMask.x;
        taps[index].mask = depthMask.y;
        taps[index].radianceCoverage = fixtureRadiance.Load(int3(index, 0, 0));
        // Exercise the installed 10/10/10/2 surface round trip. Refuse invalid
        // input BEFORE pack/saturate can make invalid evidence look valid.
        bool normalValid = beamrtNativeHistoryFinite4(rawNormalClass)
            && beamrtNativeHistoryNormalValid(rawNormalClass.xyz)
            && beamrtNativeHistoryClassValid(rawNormalClass.w);
        if (fixtureDecodeNative > 0.5)
        {
            if (normalValid)
            {
                float4 surface = sssrUnpackSurface(sssrPackSurface(float4(
                    encodeNormalXY(normalize(rawNormalClass.xyz)), 0.3, rawNormalClass.w / 3.0)));
                taps[index].normalWS = decodeNormalXY(surface.xy);
                taps[index].receiverClass = round(surface.a * 3.0);
            }
            else taps[index].mask = 0.0;
        }
        float2 axisWeight = float2((index & 1) ? phase.x : 1.0 - phase.x,
            (index & 2) ? phase.y : 1.0 - phase.y);
        float weight = axisWeight.x * axisWeight.y;
        baseline += sanitizeReflection(taps[index].radianceCoverage) * weight;
        baselineNormal += taps[index].normalWS * weight;
        baselineDepth += taps[index].linearDepth * weight;
    }
    float compatibleWeight;
    bool valid;
    float4 guarded = beamrtNativeHistoryFootprint(taps, phase, currentNormal, currentDepth,
        currentClass, FFX_DNSR_REFLECTIONS_DISOCCLUSION_NORMAL_WEIGHT,
        FFX_DNSR_REFLECTIONS_DISOCCLUSION_DEPTH_WEIGHT,
        fixtureMinimumConfidence < 0.0 ? FFX_DNSR_REFLECTIONS_DISOCCLUSION_THRESHOLD / 2.0
            : fixtureMinimumConfidence, compatibleWeight, valid);
    if (fixtureMode > 1.5)
    {
        // Algebraic model of native aggregate acceptance, using its installed
        // constants and decoded normals. NOT the full production reproject pass.
        float normalError = 1.0 - saturate(dot(normalize(currentNormal), normalize(baselineNormal)));
        float factor = exp(-normalError * FFX_DNSR_REFLECTIONS_DISOCCLUSION_NORMAL_WEIGHT
            - abs(baselineDepth / currentDepth - 1.0) * FFX_DNSR_REFLECTIONS_DISOCCLUSION_DEPTH_WEIGHT);
        return float4(factor, factor > FFX_DNSR_REFLECTIONS_DISOCCLUSION_THRESHOLD ? 1.0 : 0.0,
            valid ? 1.0 : 0.0, compatibleWeight);
    }
    return fixtureMode > 0.5 ? baseline : guarded;
}
