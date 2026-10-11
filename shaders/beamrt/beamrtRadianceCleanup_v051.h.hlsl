#ifndef BEAMRT_RADIANCE_CLEANUP_V051_H_HLSL
#define BEAMRT_RADIANCE_CLEANUP_V051_H_HLSL

// The backbuffer contains BeamNG's complete shaded result, including specular
// highlights and reflection probes.  Reusing that value verbatim as diffuse
// bounce light makes glossy reflections appear a second time.  This estimator
// keeps coherent, broad illumination while rejecting view-dependent outliers.
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

float3 beamrtDiffuseLikeRadiance(float2 prepassUv, float2 backbufferUv)
{
    float3 rawRadiance = beamrtRawDecodedBackbuffer(backbufferUv);
    float cleanupAmount = saturate(radianceCleanup);
    if (cleanupAmount <= 0.0001)
    {
        // Exact legacy path for live A/B and emergency fallback.
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

    // At a silhouette there may be no trustworthy neighbors.  Falling back to
    // the center avoids bleeding sky or body paint across unrelated geometry.
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

    // Winsorize only the bright tail.  A broad colored wall/light has similarly
    // bright neighbors and survives; a sharp probe/headlight glint does not.
    float luminanceRatio = lerp(6.0, 1.45, rejection);
    float absoluteHeadroom = lerp(1.0, 0.08, rejection);
    float luminanceCeiling = neighborLuminance * luminanceRatio + absoluteHeadroom;
    float3 limitedRadiance = rawRadiance
        * min(1.0, luminanceCeiling / max(centerLuminance, 0.0001));
    float replacementWeight = saturate(
        glossyLikelihood * rejection * max(outlier, localGradient * 0.55)
    );
    float3 robustRadiance = lerp(limitedRadiance, neighborMean, replacementWeight * 0.75);

    // Low-roughness backbuffer energy is primarily view-dependent and is a poor
    // diffuse emitter even when it covers several pixels.  Rough surfaces retain
    // their full broad color while mirror-like hits contribute conservatively.
    float diffuseTrust = lerp(1.0, 0.35 + 0.65 * centerRoughness, glossyLikelihood * rejection);
    float3 diffuseLike = robustRadiance * diffuseTrust;

#ifdef BEAMRT_DIRECT_DIFFUSE_SOURCE
    if (radianceSourceMode > 0.5)
    {
        // lightinfo0 is lighting energy, not final surface radiance. BeamNG's
        // persistent material.diffColor is unavailable to ordinary PostFX, so
        // estimate only bounded diffuse color/reflectance from the cleaned
        // scene sample. Its brightness is never reused as light energy.
        float3 directLighting = max(tex2Dlod(lightInfoTex, float4(prepassUv, 0.0, 0.0)).rgb, 0.0);
        float directLuminance = beamrtRadianceLuminance(directLighting);
        float cleanedLuminance = beamrtRadianceLuminance(diffuseLike);
        float cleanedPeak = max(max(diffuseLike.r, diffuseLike.g), diffuseLike.b);
        float3 normalizedChroma = cleanedPeak > 0.0001
            ? saturate(diffuseLike / cleanedPeak)
            : 1.0;
        float approximateReflectance = saturate(
            cleanedLuminance / max(directLuminance + 0.05, 0.05)
        );
        float chromaConfidence = saturate(cleanedPeak * 8.0);
        float3 approximateDiffuseColor = lerp(
            float3(approximateReflectance, approximateReflectance, approximateReflectance),
            normalizedChroma * approximateReflectance,
            saturate(radianceChromaStrength) * chromaConfidence
        );

        // Ordinary opaque material permutations store retroreflectivity in
        // prepass RT1.a. Rejecting it prevents road signs/plates from becoming
        // implausibly powerful diffuse emitters. Other permutations may reuse
        // alpha, so the amount remains a live, bounded control.
        float retro = saturate(tex2Dlod(materialSpecTex, float4(prepassUv, 0.0, 0.0)).a);
        float retroWeight = 1.0 - saturate(retro * max(retroReject, 0.0));
        float3 directDiffuse = directLighting * approximateDiffuseColor * retroWeight;

        // cleanup=0 remains the exact raw v0.050/v0.051 backbuffer path.
        // Increasing cleanup crossfades toward the clean direct-light source.
        return lerp(rawRadiance, directDiffuse, cleanupAmount);
    }
#endif

    return lerp(rawRadiance, diffuseLike, cleanupAmount);
}

#endif // BEAMRT_RADIANCE_CLEANUP_V051_H_HLSL
