#include "beamrtLightingCompose.h.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float beamrtContactOcclusion(PFXVertToPix IN, float4 centerDecoded)
{
    if (centerDecoded.w >= 0.9999 || contactShadowStrength <= 0.0)
    {
        return 0.0;
    }

    float uvDx = ddx(IN.uv1.x);
    float uvDy = ddy(IN.uv1.y);
    if (abs(uvDx) < 0.00000001 || abs(uvDy) < 0.00000001)
    {
        return 0.0;
    }

    float3 eyeRayDu = ddx(IN.wsEyeRay) / uvDx;
    float3 eyeRayDv = ddy(IN.wsEyeRay) / uvDy;
    float3 centerVector = IN.wsEyeRay * centerDecoded.w;
    float2 pixelDirections[8] = {
        float2( 1.0,  0.0), float2(-1.0,  0.0),
        float2( 0.0,  1.0), float2( 0.0, -1.0),
        float2( 0.7071,  0.7071), float2(-0.7071,  0.7071),
        float2( 0.7071, -0.7071), float2(-0.7071, -0.7071)
    };

    float occlusion = 0.0;
    [unroll]
    for (int sampleIndex = 0; sampleIndex < 8; ++sampleIndex)
    {
        float radiusPixels = sampleIndex < 4 ? 4.0 : 7.0;
        float2 deltaUv = pixelDirections[sampleIndex] * radiusPixels * oneOverTargetSize;
        float2 sampleUv = IN.uv1 + deltaUv;
        float4 neighborDecoded = decodeGBuffer(
            TEX_SAMPLER(prepassDepthTex),
            TEX_SAMPLER(prepassTex),
            sampleUv,
            projParams
        );
        if (neighborDecoded.w >= 0.9999)
        {
            continue;
        }

        float3 neighborEyeRay = IN.wsEyeRay + eyeRayDu * deltaUv.x + eyeRayDv * deltaUv.y;
        float3 separation = neighborEyeRay * neighborDecoded.w - centerVector;
        float distanceToSample = length(separation);
        if (distanceToSample <= 0.0001)
        {
            continue;
        }

        float horizon = saturate((dot(centerDecoded.xyz, separation / distanceToSample) - 0.04) * 3.0);
        float rangeWeight = saturate(1.0 - distanceToSample / 3.5);
        float normalCrease = lerp(0.65, 1.0, 1.0 - saturate(dot(centerDecoded.xyz, neighborDecoded.xyz)));
        occlusion += horizon * rangeWeight * normalCrease;
    }

    return saturate(occlusion * 0.22);
}

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

    // Wider depth/normal-aware reconstruction removes residual stochastic
    // grain while retaining contact edges and thin vehicle silhouettes.
    float2 pixel = oneOverTargetSize;
    float2 offsets[13] = {
        float2(0.0, 0.0),
        float2(-pixel.x, 0.0), float2(pixel.x, 0.0),
        float2(0.0, -pixel.y), float2(0.0, pixel.y),
        float2(-pixel.x, -pixel.y), float2(pixel.x, -pixel.y),
        float2(-pixel.x,  pixel.y), float2(pixel.x,  pixel.y),
        float2(-3.0 * pixel.x, 0.0), float2(3.0 * pixel.x, 0.0),
        float2(0.0, -3.0 * pixel.y), float2(0.0, 3.0 * pixel.y)
    };
    float3 giSum = 0.0;
    float weightSum = 0.0;
    float safeDepth = max(centerDecoded.w, 0.0001);
    [unroll]
    for (int sampleIndex = 0; sampleIndex < 13; ++sampleIndex)
    {
        float4 sampleGI = tex2D(temporalGITex, IN.uv1 + offsets[sampleIndex]);
        float relativeDepthDelta = abs(sampleGI.a - centerDecoded.w) / safeDepth;
        float depthWeight = 1.0 - smoothstep(0.002, 0.035, relativeDepthDelta);
        float3 sampleNormal = decodeNormalXY(tex2D(prepassTex, IN.uv1 + offsets[sampleIndex]).xy);
        float normalWeight = pow(saturate(dot(centerDecoded.xyz, sampleNormal)), 12.0);
        float spatialWeight = sampleIndex == 0 ? 4.0 : (sampleIndex < 5 ? 2.0 : (sampleIndex < 9 ? 1.25 : 0.6));
        float weight = depthWeight * normalWeight * spatialWeight;
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
    accumulatedGI = max(giLuminance.xxx + (accumulatedGI - giLuminance.xxx) * max(bounceSaturation, 0.0), 0.0);
    giLuminance = dot(accumulatedGI, luminanceWeights);
    float energyBudget = 0.35 + baseLuminance * 0.85;
    float energyScale = min(1.0, energyBudget / max(giLuminance * giStrength, 0.0001));
    float shadowLift = 1.0 - smoothstep(0.25, 3.0, baseLuminance);
    float response = lerp(0.70, 1.15, shadowLift);
    float3 indirect = accumulatedGI * giStrength * energyScale * response;
    float contactOcclusion = beamrtContactOcclusion(IN, centerDecoded);
    float contactResponse = lerp(1.0, 0.35, saturate(baseLuminance / 3.0));
    float visibility = 1.0 - contactOcclusion * saturate(contactShadowStrength) * contactResponse;
    return float4(hdrEncode(baseLinear * visibility + indirect), baseEncoded.a);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
