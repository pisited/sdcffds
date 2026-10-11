#include "beamrtLightingCompose.h.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float4 baseEncoded = tex2D(backBufferTex, IN.uv0);
    if (giStrength <= 0.0)
    {
        return baseEncoded;
    }

    float3 baseLinear = hdrDecode(baseEncoded.rgb);
    float4 centerDecoded = decodeGBuffer(
        TEX_SAMPLER(prepassDepthTex),
        TEX_SAMPLER(prepassTex),
        IN.uv1,
        projParams
    );

    // The expensive four-path trace runs at half resolution. Reconstruct a
    // smooth full-resolution result here with a small depth-aware upscale so
    // object silhouettes do not turn into the old diagnostic squares.
    float2 halfTexel = oneOverTargetSize;
    float2 offsets[5] = {
        float2(0.0, 0.0),
        float2(-halfTexel.x, -halfTexel.y),
        float2( halfTexel.x, -halfTexel.y),
        float2(-halfTexel.x,  halfTexel.y),
        float2( halfTexel.x,  halfTexel.y)
    };
    float3 giSum = 0.0;
    float weightSum = 0.0;
    float safeDepth = max(centerDecoded.w, 0.0001);
    [unroll]
    for (int sampleIndex = 0; sampleIndex < 5; ++sampleIndex)
    {
        float4 sampleGI = tex2D(temporalGITex, IN.uv1 + offsets[sampleIndex]);
        float relativeDepthDelta = abs(sampleGI.a - centerDecoded.w) / safeDepth;
        float depthWeight = 1.0 - smoothstep(0.003, 0.04, relativeDepthDelta);
        float spatialWeight = sampleIndex == 0 ? 2.0 : 1.0;
        float weight = depthWeight * spatialWeight;
        giSum += max(sampleGI.rgb, 0.0) * weight;
        weightSum += weight;
    }
    float3 accumulatedGI = weightSum > 0.0001 ? giSum / weightSum : 0.0;

    // Preserve colored bounce while preventing a bright emitter from simply
    // washing the frame out. Dark receivers get the most visible lift; already
    // bright pixels retain their direct-light contrast and highlights.
    const float3 luminanceWeights = float3(0.2126, 0.7152, 0.0722);
    float baseLuminance = dot(baseLinear, luminanceWeights);
    float giLuminance = dot(accumulatedGI, luminanceWeights);
    float energyBudget = 0.20 + baseLuminance * 0.65;
    float energyScale = min(1.0, energyBudget / max(giLuminance * giStrength, 0.0001));
    float shadowLift = 1.0 - smoothstep(0.25, 3.0, baseLuminance);
    float response = lerp(0.55, 1.0, shadowLift);
    float3 indirect = accumulatedGI * giStrength * energyScale * response;
    return float4(hdrEncode(baseLinear + indirect), baseEncoded.a);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
