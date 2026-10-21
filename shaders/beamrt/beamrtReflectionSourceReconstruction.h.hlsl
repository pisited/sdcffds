#ifndef BEAMRT_REFLECTION_SOURCE_RECONSTRUCTION_H_HLSL
#define BEAMRT_REFLECTION_SOURCE_RECONSTRUCTION_H_HLSL

#include "beamrtReflectionRadianceSafety.h.hlsl"

// Point depth, in camera-forward metres. This uses the same depth convention
// as the accepted SSR hit; neither source colour nor a filtered depth decides
// which surface a ray intersected.
bool beamrtReflectionSourceDepth(int2 pixel, out float depth)
{
    float encoded = prepassDepthTexTex.Load(int3(pixel, 0)).r;
    float eye = realToEyeLinearDepth(ndcToRealDepth(encoded, projParams.zw), projParams);
    depth = eye * projParams.y;
    return beamrtReflectionRadianceIsFinite(float3(encoded, eye, depth))
        && eye > 0.0 && eye < 0.9999 && depth > 0.0;
}

// Reciprocal forward depth is affine over a perspective-projected plane.
// Choose the less discontinuous of the two one-sided differences. A missing
// neighbour cannot establish a slope and therefore gives a flat, conservative
// estimate. This fit is only for colour-tap rejection, never ray acceptance.
float beamrtReflectionSourceSlope(float center, float before, bool beforeValid,
    float after, bool afterValid)
{
    if (!beforeValid || !afterValid) return 0.0;
    float backwards = center - before;
    float forwards = after - center;
    // A depth extremum (including a one-pixel foreground/background feature)
    // cannot justify extending a plane toward either adjacent layer.
    if (backwards * forwards <= 0.0) return 0.0;
    return abs(backwards) < abs(forwards) ? backwards : forwards;
}

float3 beamrtReflectionReconstructedSource(float2 acceptedUv, float acceptedEyeDepth,
    out float sourceCoverage)
{
    sourceCoverage = 0.0;
    if (any(abs(rtParams0.zw) < 0.000001) || any(abs(rtParams2.zw) < 0.000001)) return 0.0;
    uint depthWidth, depthHeight, sourceWidth, sourceHeight;
    prepassDepthTexTex.GetDimensions(depthWidth, depthHeight);
    backBufferTexTex.GetDimensions(sourceWidth, sourceHeight);
    int2 depthSize = int2(depthWidth, depthHeight);
    int2 sourceSize = int2(sourceWidth, sourceHeight);
    int2 anchorPixel = int2(floor(acceptedUv * depthSize));
    if (any(anchorPixel < 0) || any(anchorPixel >= depthSize)) return 0.0;
    float2 depthViewportMin = min(rtParams0.xy, rtParams0.xy + rtParams0.zw);
    float2 depthViewportMax = max(rtParams0.xy, rtParams0.xy + rtParams0.zw);
    float2 sourceViewportMin = min(rtParams2.xy, rtParams2.xy + rtParams2.zw);
    float2 sourceViewportMax = max(rtParams2.xy, rtParams2.xy + rtParams2.zw);
    float anchorDepth;
    if (!beamrtReflectionSourceDepth(anchorPixel, anchorDepth)) return 0.0;
    // Do not widen the ray's configured thickness. Only a few millimetres of
    // colour/depth raster precision are tolerated, capped at three centimetres.
    float tolerance = max(0.002, min(0.03, anchorDepth * 0.0005));
    if (abs(anchorDepth - acceptedEyeDepth * projParams.y) > tolerance) return 0.0;
    float inverseDepth = rcp(anchorDepth);
    float2 inverseSlope = 0.0;
    [unroll] for (int axis = 0; axis < 2; ++axis)
    {
        int2 offset = axis == 0 ? int2(1, 0) : int2(0, 1);
        int2 beforePixel = anchorPixel - offset;
        int2 afterPixel = anchorPixel + offset;
        float2 beforeUv = (float2(beforePixel) + 0.5) / depthSize;
        float2 afterUv = (float2(afterPixel) + 0.5) / depthSize;
        bool beforeValid = all(beforePixel >= 0) && all(beforePixel < depthSize)
            && all(beforeUv >= depthViewportMin) && all(beforeUv < depthViewportMax);
        bool afterValid = all(afterPixel >= 0) && all(afterPixel < depthSize)
            && all(afterUv >= depthViewportMin) && all(afterUv < depthViewportMax);
        float beforeDepth = anchorDepth, afterDepth = anchorDepth;
        if (beforeValid) beforeValid = beamrtReflectionSourceDepth(beforePixel, beforeDepth);
        if (afterValid) afterValid = beamrtReflectionSourceDepth(afterPixel, afterDepth);
        inverseSlope[axis] = beamrtReflectionSourceSlope(inverseDepth,
            rcp(max(beforeDepth, 0.000001)), beforeValid,
            rcp(max(afterDepth, 0.000001)), afterValid);
    }
    float2 viewportUv = (acceptedUv - rtParams0.xy) / rtParams0.zw;
    float2 sourceUv = viewportCoordToRenderTarget(viewportUv, rtParams2);
    float2 sourcePosition = sourceUv * sourceSize - 0.5;
    int2 basePixel = int2(floor(sourcePosition));
    float2 fraction = frac(sourcePosition);
    float3 accumulated = 0.0;
    [unroll] for (int y = 0; y < 2; ++y)
    [unroll] for (int x = 0; x < 2; ++x)
    {
        int2 sourcePixel = basePixel + int2(x, y);
        if (any(sourcePixel < 0) || any(sourcePixel >= sourceSize)) continue;
        float2 tapSourceUv = (float2(sourcePixel) + 0.5) / sourceSize;
        if (any(tapSourceUv < sourceViewportMin) || any(tapSourceUv >= sourceViewportMax)) continue;
        float2 tapViewUv = (tapSourceUv - rtParams2.xy) / rtParams2.zw;
        float2 tapDepthUv = viewportCoordToRenderTarget(tapViewUv, rtParams0);
        int2 depthPixel = int2(floor(tapDepthUv * depthSize));
        if (any(depthPixel < 0) || any(depthPixel >= depthSize)) continue;
        float2 sampledDepthUv = (float2(depthPixel) + 0.5) / depthSize;
        if (any(sampledDepthUv < depthViewportMin) || any(sampledDepthUv >= depthViewportMax)) continue;
        float tapDepth;
        if (!beamrtReflectionSourceDepth(depthPixel, tapDepth)) continue;
        float predictedInverse = inverseDepth + dot(inverseSlope, float2(depthPixel - anchorPixel));
        if (predictedInverse <= 0.0) continue;
        float predictedDepth = rcp(predictedInverse);
        if (!beamrtReflectionRadianceIsFinite(float3(predictedDepth, tapDepth, 0.0))
            || abs(tapDepth - predictedDepth) > tolerance) continue;
        // Decode each original source texel separately. Never filter encoded
        // HDR or allow a nonfinite tap into a weighted accumulation.
        float3 tapRadiance = hdrDecode(backBufferTexTex.Load(int3(sourcePixel, 0)).rgb);
        if (!beamrtReflectionRadianceIsFinite(tapRadiance)) continue;
        float2 axes = lerp(1.0 - fraction, fraction, float2(x, y));
        float weight = axes.x * axes.y;
        accumulated += max(tapRadiance, 0.0) * weight;
        sourceCoverage += weight;
    }
    // Missing colour support is black, NOT a ray miss. The caller preserves
    // confidence, accepted-black category and exact packed hit UV metadata.
    return sourceCoverage > 0.000001 ? accumulated / sourceCoverage : 0.0;
}

#endif
