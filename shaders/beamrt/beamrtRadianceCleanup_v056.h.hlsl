#ifndef BEAMRT_RADIANCE_CLEANUP_V056_H_HLSL
#define BEAMRT_RADIANCE_CLEANUP_V056_H_HLSL

// The backbuffer contains BeamNG's complete shaded result, including specular
// highlights and reflection probes. Reusing it verbatim as diffuse bounce light
// makes glossy reflections appear a second time. This estimator preserves broad
// surface color while rejecting view-dependent outliers.
float beamrtRadianceLuminance(float3 color)
{
    return dot(max(color, 0.0), float3(0.2126, 0.7152, 0.0722));
}

float3 beamrtRawDecodedBackbuffer(float2 uv)
{
    return min(hdrDecode(tex2Dlod(backBufferTex, float4(uv, 0.0, 0.0)).rgb), 65504.0);
}

float3 beamrtDecodedBackbuffer(float2 uv)
{
    return max(beamrtRawDecodedBackbuffer(uv), 0.0);
}

float2 beamrtLightInfoUvFromPrepassUv(float2 prepassUv)
{
#ifdef BEAMRT_LIGHTINFO_SLOT3
    // processPostFxVert provides a target transform only for slots 0..3.
    // Convert slot-0 prepass coordinates back to viewport space, then apply
    // slot 3's independently supplied lightinfo target transform.
    float2 safePrepassScale = max(abs(rtParams0.zw), float2(0.000001, 0.000001));
    float2 viewportUv = (prepassUv - rtParams0.xy) / safePrepassScale;
    return viewportCoordToRenderTarget(viewportUv, rtParams3);
#else
    // Retained for source compatibility with the v0.054 slot layout.
    return prepassUv;
#endif
}

float3 beamrtDiffuseLikeRadiance(float2 prepassUv, float2 backbufferUv)
{
    float3 rawRadiance = beamrtRawDecodedBackbuffer(backbufferUv);
    float cleanupAmount = saturate(radianceCleanup);
    if (cleanupAmount <= 0.0001)
    {
        // Exact raw-backbuffer path for live A/B and emergency fallback.
        return rawRadiance;
    }

    rawRadiance = max(rawRadiance, 0.0);

    float rejection = saturate(specularReject);
    uint prepassWidth;
    uint prepassHeight;
    uint backbufferWidth;
    uint backbufferHeight;
    prepassTexTex.GetDimensions(prepassWidth, prepassHeight);
    backBufferTexTex.GetDimensions(backbufferWidth, backbufferHeight);
    float2 prepassTexel = 2.0 / max(float2(prepassWidth, prepassHeight), float2(1.0, 1.0));
    float2 backbufferTexel = 2.0 / max(float2(backbufferWidth, backbufferHeight), float2(1.0, 1.0));
    float2 directions[4] = {
        float2(1.0, 0.0), float2(-1.0, 0.0),
        float2(0.0, 1.0), float2(0.0, -1.0)
    };

    float4 centerPacked = tex2Dlod(prepassTex, float4(prepassUv, 0.0, 0.0));
    float centerDepthNdc = tex2Dlod(prepassDepthTex, float4(prepassUv, 0.0, 0.0)).r;
    float centerRealDepth = ndcToRealDepth(centerDepthNdc, projParams.zw);
    float centerEyeDepth = realToEyeLinearDepth(centerRealDepth, projParams);
    float3 centerNormal = decodeNormalXY(centerPacked.xy);
    float centerRoughness = saturate(centerPacked.b);
    float centerLuminance = beamrtRadianceLuminance(rawRadiance);

    float3 neighborSum = 0.0;
    float neighborWeightSum = 0.0;
    [unroll]
    for (int sampleIndex = 0; sampleIndex < 4; ++sampleIndex)
    {
        float2 samplePrepassUv = prepassUv + directions[sampleIndex] * prepassTexel;
        float2 sampleBackbufferUv = backbufferUv + directions[sampleIndex] * backbufferTexel;
        float4 samplePacked = tex2Dlod(prepassTex, float4(samplePrepassUv, 0.0, 0.0));
        float sampleDepthNdc = tex2Dlod(prepassDepthTex, float4(samplePrepassUv, 0.0, 0.0)).r;
        float sampleRealDepth = ndcToRealDepth(sampleDepthNdc, projParams.zw);
        float sampleEyeDepth = realToEyeLinearDepth(sampleRealDepth, projParams);
        float3 sampleNormal = decodeNormalXY(samplePacked.xy);

        float normalWeight = pow(saturate(dot(centerNormal, sampleNormal)), 16.0);
        float worldDepthDelta = abs(centerEyeDepth - sampleEyeDepth) * projParams.y;
        float depthTolerance = max(0.10, centerEyeDepth * projParams.y * 0.01);
        float depthWeight = 1.0 - smoothstep(depthTolerance, depthTolerance * 2.5, worldDepthDelta);
        float weight = normalWeight * depthWeight;
        neighborSum += beamrtDecodedBackbuffer(sampleBackbufferUv) * weight;
        neighborWeightSum += weight;
    }

    float3 neighborMean = neighborWeightSum > 0.001
        ? neighborSum / neighborWeightSum
        : rawRadiance;
    float neighborLuminance = beamrtRadianceLuminance(neighborMean);
    float glossyLikelihood = (1.0 - centerRoughness) * (1.0 - centerRoughness);
    float localGradient = abs(centerLuminance - neighborLuminance)
        / max(centerLuminance + neighborLuminance, 0.05);
    float outlier = saturate(
        (centerLuminance - neighborLuminance * 1.15 - 0.03)
        / max(neighborLuminance * 1.5 + 0.08, 0.08)
    );

    float luminanceRatio = lerp(6.0, 1.45, rejection);
    float absoluteHeadroom = lerp(1.0, 0.08, rejection);
    float luminanceCeiling = neighborLuminance * luminanceRatio + absoluteHeadroom;
    float3 limitedRadiance = rawRadiance
        * min(1.0, luminanceCeiling / max(centerLuminance, 0.0001));
    float replacementWeight = saturate(
        glossyLikelihood * rejection * max(outlier, localGradient * 0.55)
    );
    float3 robustRadiance = lerp(limitedRadiance, neighborMean, replacementWeight * 0.75);

    float diffuseTrust = lerp(1.0, 0.35 + 0.65 * centerRoughness, glossyLikelihood * rejection);
    float3 diffuseLike = robustRadiance * diffuseTrust;

#ifdef BEAMRT_DIRECT_DIFFUSE_SOURCE
    if (radianceSourceMode > 0.5)
    {
        // lightinfo0 is incident/direct-light energy. The cleaned scene sample
        // already contains materialColor * lighting, so recover reflectance by
        // dividing out lighting component-wise. Never normalize illuminated
        // chroma and multiply it by the same colored lighting a second time.
        float2 lightInfoUv = beamrtLightInfoUvFromPrepassUv(prepassUv);
        float3 directLighting = max(
            tex2Dlod(lightInfoTex, float4(lightInfoUv, 0.0, 0.0)).rgb,
            0.0
        );
        float3 channelFloor = float3(0.04, 0.04, 0.04);
        float3 rawAlbedoEstimate = saturate(diffuseLike / max(directLighting, channelFloor));

        // Poorly illuminated channels cannot provide a stable division. Blend
        // those channels toward a neutral scalar estimate rather than allowing
        // noise or ambient/specular residuals to invent extreme surface color.
        float directLuminance = beamrtRadianceLuminance(directLighting);
        float cleanedLuminance = beamrtRadianceLuminance(diffuseLike);
        float scalarReflectance = saturate(
            cleanedLuminance / max(directLuminance, 0.04)
        );
        float3 channelConfidence = smoothstep(
            float3(0.02, 0.02, 0.02),
            float3(0.15, 0.15, 0.15),
            directLighting
        );
        float3 stableAlbedo = lerp(
            float3(scalarReflectance, scalarReflectance, scalarReflectance),
            rawAlbedoEstimate,
            channelConfidence
        );
        float3 estimatedDiffuseColor = lerp(
            float3(scalarReflectance, scalarReflectance, scalarReflectance),
            stableAlbedo,
            saturate(radianceChromaStrength)
        );
        float3 reconstructed = directLighting * estimatedDiffuseColor;
        float reconstructionConfidence = smoothstep(0.04, 0.25, directLuminance);
        float3 sourceRadiance = lerp(diffuseLike, reconstructed, reconstructionConfidence);

        // Ordinary opaque material permutations store retroreflectivity in
        // prepass RT1.a. Reject it after reconstruction so the fallback used in
        // uncertain/dark regions cannot preserve amplified retro response.
        float retro = saturate(tex2Dlod(materialSpecTex, float4(prepassUv, 0.0, 0.0)).a);
        float retroWeight = 1.0 - saturate(retro * max(retroReject, 0.0));
        float3 directDiffuse = sourceRadiance * retroWeight;

        // cleanup=0 remains the exact raw backbuffer path. Source=legacy keeps
        // the cleaned-backbuffer-only path below for direct A/B testing.
        return lerp(rawRadiance, directDiffuse, cleanupAmount);
    }
#endif

    return lerp(rawRadiance, diffuseLike, cleanupAmount);
}

#endif // BEAMRT_RADIANCE_CLEANUP_V056_H_HLSL
