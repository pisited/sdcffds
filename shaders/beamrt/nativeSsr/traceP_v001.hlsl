// BeamRT-owned SSSR fork v001. Native-derived MIT pixel-plane traversal;
// existing BeamRT sampling, source reconstruction, temporal/composite contracts.
// Not full native parity: no owned Hi-Z, water capture or native material pass.
#define BEAMRT_REFLECTION_SOURCE_RECONSTRUCTION 1
#define BEAMRT_REFLECTION_SAFE_RADIANCE 1
#define BEAMRT_REFLECTION_TUNING 1
#define BEAMRT_REFLECTION_CONVERGENCE 1
#define BEAMRT_REFLECTION_COLOR_FILTER 1
#define BEAMRT_REFLECTION_HIT_AWARE 1
#define BEAMRT_REFLECTION_GGX 1
#define BEAMRT_REFLECTION_FIRST_SURFACE 1
#define BEAMRT_REFLECTION_DIAGNOSTICS 1
#define BEAMRT_SSSR_FORK_LAB 1
// BeamRT's existing origin/near-plane/viewport contract is retained.
// Accepted hits store nonnegative, confidence-premultiplied radiance. Existing
// environment/material reflections remain: this is augmentation, not exact lobe
// replacement. No complete receiver beauty color is subtracted here.
// A native-derived continuous pixel-plane intersection replaces linear steps
// and binary refinement; validated source/color/output contracts remain shared.
#include "../beamrtReflectionTrace.h.hlsl"
#ifdef BEAMRT_REFLECTION_SAFE_RADIANCE
#include "../beamrtReflectionRadianceSafety.h.hlsl"
#endif
#ifdef BEAMRT_REFLECTION_HIT_AWARE
#include "../beamrtReflectionHitPacking.h.hlsl"
#endif
#ifdef BEAMRT_REFLECTION_COLOR_FILTER
#include "../beamrtReflectionSourceFilter.h.hlsl"
#endif
#ifdef BEAMRT_REFLECTION_SOURCE_RECONSTRUCTION
#include "../beamrtReflectionSourceReconstruction.h.hlsl"
#endif

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

#ifdef BEAMRT_REFLECTION_GGX
// Isotropic visible-normal sampling from Heitz, JCGT 7(4), 2018.
// https://jcgt.org/published/0007/04/01/paper.pdf
// The native G-buffer stores perceptual roughness r; GGX alpha is r*r.
uint beamrtReflectionGGXHash(uint value)
{
    value ^= value >> 16;
    value *= 0x7feb352du;
    value ^= value >> 15;
    value *= 0x846ca68bu;
    return value ^ (value >> 16);
}

float2 beamrtReflectionGGXSample(uint2 pixel, uint sampleIndex)
{
#ifdef BEAMRT_REFLECTION_TUNING
    // Change spatial correlation only. Still one ray at the original receiver;
    // cell < 1 scrambles seeds, not subpixel sampling or extra geometry detail.
    float cell = clamp(reflectionSampleCellPixels, 0.25, 4.0);
    if (cell != 1.0) pixel = uint2(floor(float2(pixel) / cell));
#endif
    uint seed = beamrtReflectionGGXHash(pixel.x ^ (pixel.y * 0x9e3779b9u));
#ifdef BEAMRT_REFLECTION_TUNING
    uint salt = (uint)clamp(reflectionNoiseSeed, 0.0, 65535.0);
    if (salt != 0u) seed = beamrtReflectionGGXHash(seed ^ (salt * 0x9e3779b9u));
#endif
    // Per-pixel Cranley-Patterson rotation of an integer Weyl/R2 sequence.
    // Unsigned increments avoid loss of fractional precision on long runs.
    // No 64/128-frame sequence, external atlas, or conditional resampling.
    uint2 sequence = uint2(seed, beamrtReflectionGGXHash(seed ^ 0xa511e9b3u))
        + sampleIndex * uint2(0xc13fa9a9u, 0x91e10da5u);
    return float2(sequence >> 8) * (1.0 / 16777216.0);
}

float3 beamrtReflectionSampleGGXVNDF(float3 viewLocal, float alpha, float2 sample)
{
    float3 viewStretched = normalize(float3(alpha * viewLocal.xy, viewLocal.z));
    float lengthSquared = dot(viewStretched.xy, viewStretched.xy);
    float3 tangent1 = lengthSquared > 0.0
        ? float3(-viewStretched.y, viewStretched.x, 0.0) * rsqrt(lengthSquared)
        : float3(1.0, 0.0, 0.0);
    float3 tangent2 = cross(viewStretched, tangent1);
    float radius = sqrt(sample.x);
    float phi = 6.283185307179586 * sample.y;
    float t1 = radius * cos(phi);
    float t2 = radius * sin(phi);
    float blend = 0.5 * (1.0 + viewStretched.z);
    t2 = (1.0 - blend) * sqrt(max(0.0, 1.0 - t1 * t1)) + blend * t2;
    float3 normalStretched = t1 * tangent1 + t2 * tangent2
        + sqrt(max(0.0, 1.0 - t1 * t1 - t2 * t2)) * viewStretched;
    return normalize(float3(alpha * normalStretched.xy, max(0.0, normalStretched.z)));
}

float3 beamrtReflectionGGXThroughput(
    float3 specularF0, float alpha, float nDotV, float nDotL, float vDotH)
{
    float alphaSquared = alpha * alpha;
    float rootV = sqrt(alphaSquared + (1.0 - alphaSquared) * nDotV * nDotV);
    float rootL = sqrt(alphaSquared + (1.0 - alphaSquared) * nDotL * nDotL);
    // Height-correlated Smith G2/G1(V), exactly equivalent to
    // (1+lambda(V))/(1+lambda(V)+lambda(L)), without grazing-angle divisions.
    float smithRatio = nDotL * (nDotV + rootV) / (nDotL * rootV + nDotV * rootL);
    float3 fresnel = specularF0 + (1.0 - specularF0) * pow(1.0 - saturate(vDotH), 5.0);
    // VNDF pdf cancels D, NdotL and G1(V). Apply this weight once in trace.
    return fresnel * smithRatio;
}
#endif

bool beamrtProjectEyeVector(
    float3 eyeVector,
    float3 currentEyeRay,
    float3 eyeRayDu,
    float3 eyeRayDv,
    float2 currentUv,
    out float2 projectedUv,
    out float projectedDepth)
{
    float3 duCrossDv = cross(eyeRayDu, eyeRayDv);
    float determinant = dot(currentEyeRay, duCrossDv);
    if (abs(determinant) < 0.00000001)
    {
        projectedUv = 0.0;
        projectedDepth = 0.0;
        return false;
    }

    projectedDepth = dot(eyeVector, duCrossDv) / determinant;
    float weightedDu = dot(currentEyeRay, cross(eyeVector, eyeRayDv)) / determinant;
    float weightedDv = dot(currentEyeRay, cross(eyeRayDu, eyeVector)) / determinant;
    if (projectedDepth <= 0.00000001)
    {
        projectedUv = 0.0;
        return false;
    }

    projectedUv = currentUv + float2(weightedDu, weightedDv) / projectedDepth;
    return true;
}

float2 beamrtPrepassUvToBackbufferUv(float2 prepassUv)
{
    float2 viewportUv = (prepassUv - rtParams0.xy) / rtParams0.zw;
    return viewportCoordToRenderTarget(viewportUv, rtParams2);
}

float beamrtEdgeConfidence(float2 uv)
{
    float2 otherCorner = rtParams0.xy + rtParams0.zw;
    float2 viewportMin = min(rtParams0.xy, otherCorner);
    float2 viewportMax = max(rtParams0.xy, otherCorner);
    float2 normalizedUv = (uv - viewportMin) / max(viewportMax - viewportMin, 0.000001);
    float edgeDistance = min(min(normalizedUv.x, normalizedUv.y), min(1.0 - normalizedUv.x, 1.0 - normalizedUv.y));
    return smoothstep(0.0, 0.08, edgeDistance);
}

float beamrtSceneEyeDepth(float2 uv)
{
    float sceneNdcDepth = tex2Dlod(prepassDepthTex, float4(uv, 0.0, 0.0)).r;
    float sceneRealDepth = ndcToRealDepth(sceneNdcDepth, projParams.zw);
    return realToEyeLinearDepth(sceneRealDepth, projParams);
}

#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
// State: 0 untraced, 1 miss, 2 crossing rejected, 3 accepted geometry.
// Mode 8 palette: grey untraced; magenta work end; purple left view;
// blue background; cyan missing front sample; orange coarse bracket;
// pink negative refined depth (defensive gate); white screen travel;
// red refined thickness; brown backface; dark grey receiver direction;
// green accepted. A later accepted candidate supersedes earlier rejections;
// otherwise retain the last rejected crossing or encountered miss cause.
#define BEAMRT_SSR_UNTRACED 0
#define BEAMRT_SSR_WORK_END 1
#define BEAMRT_SSR_LEFT_VIEW 2
#define BEAMRT_SSR_BACKGROUND 3
#define BEAMRT_SSR_NO_FRONT 4
#define BEAMRT_SSR_BRACKET 5
#define BEAMRT_SSR_NEGATIVE_DEPTH 7
#define BEAMRT_SSR_SCREEN_TRAVEL 8
#define BEAMRT_SSR_THICKNESS 9
#define BEAMRT_SSR_BACKFACE 10
#define BEAMRT_SSR_RECEIVER_DIRECTION 11
#define BEAMRT_SSR_ACCEPTED 12
#define BEAMRT_SSR_INVALID_INPUT 13
#define BEAMRT_SSR_SEGMENT_END 14
#define BEAMRT_SSR_NATIVE_VALIDATION 15

float3 beamrtReflectionReasonColour(int reason)
{
    if (reason == BEAMRT_SSR_WORK_END) return float3(1.0, 0.0, 1.0);
    if (reason == BEAMRT_SSR_LEFT_VIEW) return float3(0.55, 0.0, 1.0);
    if (reason == BEAMRT_SSR_BACKGROUND) return float3(0.0, 0.25, 1.0);
    if (reason == BEAMRT_SSR_NO_FRONT) return float3(0.0, 1.0, 1.0);
    if (reason == BEAMRT_SSR_BRACKET) return float3(1.0, 0.5, 0.0);
    if (reason == BEAMRT_SSR_NEGATIVE_DEPTH) return float3(1.0, 0.25, 0.5);
    if (reason == BEAMRT_SSR_SCREEN_TRAVEL) return float3(1.0, 1.0, 1.0);
    if (reason == BEAMRT_SSR_THICKNESS) return float3(1.0, 0.0, 0.0);
    if (reason == BEAMRT_SSR_BACKFACE) return float3(0.5, 0.25, 0.0);
    if (reason == BEAMRT_SSR_RECEIVER_DIRECTION) return float3(0.1, 0.1, 0.1);
    if (reason == BEAMRT_SSR_ACCEPTED) return float3(0.0, 1.0, 0.0);
    if (reason == BEAMRT_SSR_INVALID_INPUT) return float3(1.0, 1.0, 0.0);
    if (reason == BEAMRT_SSR_SEGMENT_END) return float3(0.0, 0.5, 0.5);
    if (reason == BEAMRT_SSR_NATIVE_VALIDATION) return float3(0.65, 0.65, 1.0);
    return float3(0.25, 0.25, 0.25);
}

float4 beamrtReflectionDiagnostic(
    int mode, int state, int reason, float2 hitUv,
    float depthErrorWorld, float safeThickness)
{
    float3 validity = state == 3 ? float3(0.0, 1.0, 0.0)
        : (state == 2 ? float3(1.0, 0.0, 0.0)
        : (state == 1 ? float3(1.0, 0.0, 1.0) : float3(0.25, 0.25, 0.25)));
    // Composite diagnostics need the same zero radiance/alpha as production
    // for every untraced, missed, or rejected ray.
    if (mode == 6)
        return 0.0;
    if (mode == 3 && state == 3)
        return float4(hitUv, 0.0, 1.0);
    if (mode == 7 && state == 3)
        return float4(beamrtPrepassUvToBackbufferUv(hitUv), 0.0, 1.0);
    if (mode == 4 && (state == 2 || state == 3))
    {
        // Error is (ray eye depth - scene eye depth) * camera far, in metres.
        // R=min(abs(error)/safeThickness,1), G=1-R; B=0 accepted, .5 rejected.
        // This shows the existing acceptance slab; it does not widen it.
        float errorRatio = saturate(abs(depthErrorWorld) / max(safeThickness, 0.02));
        return float4(errorRatio, 1.0 - errorRatio, state == 3 ? 0.0 : 0.5, 1.0);
    }
    if (mode == 8)
        return float4(beamrtReflectionReasonColour(reason), 1.0);
    return float4(validity, 1.0);
}
#endif

// Clip one affine homogeneous halfspace, retaining the ray's actual world
// travel interval. UV/depth clipping then also bounds every refinement point.
bool beamrtClipReflectionHalfspace(
    float originValue,
    float raySlope,
    inout float minimumTravel,
    inout float maximumTravel)
{
    if (abs(raySlope) <= 0.000000000001)
    {
        return originValue >= 0.0;
    }

    float boundaryTravel = -originValue / raySlope;
    if (raySlope > 0.0)
    {
        minimumTravel = max(minimumTravel, boundaryTravel);
    }
    else
    {
        maximumTravel = min(maximumTravel, boundaryTravel);
    }
    return maximumTravel >= minimumTravel;
}

#include "adapter.h.hlsl"

float4 mainP(PFXVertToPix IN) : SV_Target0
{
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
    int diagnosticMode = (int)clamp(reflectionDebugMode, 0.0, 9.0);
#endif
    float4 packedPrepass = tex2D(prepassTex, IN.uv0);
    float4 decoded = decodeGBuffer(
        TEX_SAMPLER(prepassDepthTex),
        TEX_SAMPLER(prepassTex),
        IN.uv0,
        projParams
    );
    if (!beamrtSssrFinite(packedPrepass) || !beamrtSssrFinite(decoded)) return 0.0;
    float roughness = max(packedPrepass.b, 0.02);
    if (decoded.w >= 0.9999 || roughness >= max(reflectionMaxRoughness, 0.021))
    {
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
        if (diagnosticMode > 0)
            return beamrtReflectionDiagnostic(diagnosticMode, 0, BEAMRT_SSR_UNTRACED, 0.0, 0.0, 0.02);
#endif
        return 0.0;
    }

    float uvDx = ddx(IN.uv0.x);
    float uvDy = ddy(IN.uv0.y);
    if (abs(uvDx) < 0.00000001 || abs(uvDy) < 0.00000001)
    {
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
        if (diagnosticMode > 0)
            return beamrtReflectionDiagnostic(diagnosticMode, 0, BEAMRT_SSR_LEFT_VIEW, 0.0, 0.0, 0.02);
#endif
        return 0.0;
    }

    float3 worldPosition = eyePosWorld + IN.wsEyeRay * decoded.w;
    float3 eyeRayDu = ddx(IN.wsEyeRay) / uvDx;
    float3 eyeRayDv = ddy(IN.wsEyeRay) / uvDy;
    float3 viewTravel = normalize(worldPosition - eyePosWorld);
    float3 rayDirection = normalize(reflect(viewTravel, decoded.xyz));
    if (dot(rayDirection, decoded.xyz) <= 0.001)
    {
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
        if (diagnosticMode > 0)
            return beamrtReflectionDiagnostic(diagnosticMode, 0, BEAMRT_SSR_RECEIVER_DIRECTION, 0.0, 0.0, 0.02);
#endif
        return 0.0;
    }
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
    // Receiver view identifies eligibility before intersection. Green says
    // this pixel passes the existing depth/roughness/ray-direction gates;
    // it does not assert that native material roughness is incorrect.
    if (diagnosticMode == 1)
        return float4(0.0, 1.0, 0.0, 1.0);
#ifndef BEAMRT_REFLECTION_GGX
    if (diagnosticMode == 9)
        return float4(rayDirection * 0.5 + 0.5, 1.0);
#endif
#endif

#ifdef BEAMRT_REFLECTION_GGX
    bool useGGX = reflectionSamplingMode > 0.5;
    float3 reflectionThroughput = 1.0;
    if (useGGX)
    {
        float3 normalWS = normalize(decoded.xyz);
        float3 toEye = normalize(-IN.wsEyeRay);
        float nDotV = dot(normalWS, toEye);
        if (nDotV <= 0.0)
        {
            if (diagnosticMode > 0)
                return beamrtReflectionDiagnostic(diagnosticMode, 0,
                    BEAMRT_SSR_RECEIVER_DIRECTION, 0.0, 0.0, 0.02);
            return 0.0;
        }
        float3 basisUp = abs(normalWS.z) < 0.999
            ? float3(0.0, 0.0, 1.0) : float3(0.0, 1.0, 0.0);
        float3 tangentWS = normalize(cross(basisUp, normalWS));
        float3 bitangentWS = cross(normalWS, tangentWS);
        float3 viewLocal = float3(dot(toEye, tangentWS), dot(toEye, bitangentWS), nDotV);
        uint sampleWidth;
        uint sampleHeight;
        prepassTexTex.GetDimensions(sampleWidth, sampleHeight);
        uint2 samplePixel = uint2(floor(IN.uv0 * float2(sampleWidth, sampleHeight)));
        uint sampleIndex = (uint)max(reflectionSampleIndex, 0.0);
        float alpha = roughness * roughness;
        float3 halfLocal = beamrtReflectionSampleGGXVNDF(viewLocal, alpha,
            beamrtReflectionGGXSample(samplePixel, sampleIndex));
        float3 halfWS = normalize(tangentWS * halfLocal.x
            + bitangentWS * halfLocal.y + normalWS * halfLocal.z);
#ifdef BEAMRT_REFLECTION_HIT_AWARE
        // Delta-mirror approximation only for nearly polished materials.
        // Rougher materials retain the unmodified stochastic GGX distribution.
        if (reflectionStableSmoothEnabled > 0.5 && roughness <= 0.035)
            halfWS = normalWS;
#endif
        rayDirection = normalize(reflect(-toEye, halfWS));
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
        if (diagnosticMode == 9)
            return float4(rayDirection * 0.5 + 0.5, 1.0);
#endif
        float nDotL = dot(normalWS, rayDirection);
        // A VNDF microfacet can reflect below the macro-surface. Its sample
        // contributes zero; retrying until above the surface would bias energy.
        if (nDotL <= 0.0)
        {
#ifdef BEAMRT_REFLECTION_CONVERGENCE
            if (reflectionConvergenceEnabled > 0.5 && diagnosticMode == 0)
                return float4(0, 0, 0, -1); // known BRDF-domain zero, not unknown SSR miss
#endif
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
            if (diagnosticMode > 0)
                return beamrtReflectionDiagnostic(diagnosticMode, 0,
                    BEAMRT_SSR_RECEIVER_DIRECTION, 0.0, 0.0, 0.02);
#endif
            return 0.0;
        }
        float3 specularF0 = saturate(tex2D(materialSpecTex, IN.uv0).rgb);
        reflectionThroughput = beamrtReflectionGGXThroughput(specularF0,
            alpha, saturate(nDotV), saturate(nDotL), dot(toEye, halfWS));
    }
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
    else if (diagnosticMode == 9)
        return float4(rayDirection * 0.5 + 0.5, 1.0);
#endif
#endif

    float3 rayOrigin = worldPosition + decoded.xyz * max(reflectionNormalBias, 0.0);
    float safeStep = max(reflectionStepSize, 0.02);
    float safeThickness = max(reflectionThickness, 0.02);
    float maxDistance = max(reflectionMaxDistance, safeStep);
    int maxSteps = (int)clamp(reflectionMaxSteps, 1.0, 96.0);
    float2 otherCorner = rtParams0.xy + rtParams0.zw;
    float2 viewportMin = min(rtParams0.xy, otherCorner);
    float2 viewportMax = max(rtParams0.xy, otherCorner);
    float2 uvTexel = max(float2(abs(uvDx), abs(uvDy)), 0.000001);
#ifdef BEAMRT_REFLECTION_FIRST_SURFACE
    // Compare the real depth texture's point texels, not output pixel size.
    // The receiver coordinate remains immutable throughout the march.
    uint depthWidth;
    uint depthHeight;
    prepassDepthTexTex.GetDimensions(depthWidth, depthHeight);
    float2 depthTextureSize = max(float2(depthWidth, depthHeight), 1.0);
    int2 depthMaximumPixel = max(int2(depthTextureSize) - 1, int2(0, 0));
    const int2 receiverDepthPixel = clamp(int2(IN.uv0 * depthTextureSize),
        int2(0, 0), depthMaximumPixel);
    // A unit ray's existing zero-bias 1 mm probe can advance at most 1 mm
    // in forward depth. A few float32 rounding units scale with receiver
    // depth, but neither numerical allowance nor departure travel exceeds
    // 2 mm. User thickness and normal bias cannot enlarge this exception.
    const float receiverDepartureTravel = 0.002;
    const float receiverDepthTolerance = min(0.002,
        max(0.001, abs(decoded.w * projParams.y) * 0.0000005));
#endif

    // Eye-linear depth is view-space metres / far, hence native near = x/y.
    float minimumProjectedDepth = max(
        projParams.x / max(projParams.y, 0.0001), 0.00000001);
    float depthGuard = max(minimumProjectedDepth * 0.00001, 0.000000001);
    float2 clipViewportMin = viewportMin + uvTexel * 0.001;
    float2 clipViewportMax = viewportMax - uvTexel * 0.001;
    float3 duCrossDv = cross(eyeRayDu, eyeRayDv);
    float projectionDeterminant = dot(IN.wsEyeRay, duCrossDv);
    if (abs(projectionDeterminant) < 0.00000001)
    {
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
        if (diagnosticMode > 0)
            return beamrtReflectionDiagnostic(diagnosticMode, 1, BEAMRT_SSR_LEFT_VIEW, 0.0, 0.0, safeThickness);
#endif
        return 0.0;
    }
    float inverseDeterminant = 1.0 / projectionDeterminant;
    float3 originEyeVector = rayOrigin - eyePosWorld;
    float depthIntercept = dot(originEyeVector, duCrossDv) * inverseDeterminant;
    float depthSlope = dot(rayDirection, duCrossDv) * inverseDeterminant;
    float duIntercept = dot(IN.wsEyeRay, cross(originEyeVector, eyeRayDv)) * inverseDeterminant;
    float duSlope = dot(IN.wsEyeRay, cross(rayDirection, eyeRayDv)) * inverseDeterminant;
    float dvIntercept = dot(IN.wsEyeRay, cross(eyeRayDu, originEyeVector)) * inverseDeterminant;
    float dvSlope = dot(IN.wsEyeRay, cross(eyeRayDu, rayDirection)) * inverseDeterminant;

    float minimumTravel = 0.0;
    bool extendedWork = beamrtSssrFinite(float4(reflectionForkWork, 0, 0))
        && reflectionForkWork.x > 0.0 && reflectionForkWork.y > 0.0;
    float maximumTravel = extendedWork ? clamp(reflectionForkWork.y, 0.02, 64.0)
        : min(maxDistance, safeStep * (float)maxSteps);
    if (extendedWork) maxDistance = maximumTravel;
    uint lookupBudget = extendedWork ? (uint)clamp(reflectionForkWork.x, 5.0, 2048.0)
        : (uint)maxSteps * 5u;
    bool visibleSegment = beamrtClipReflectionHalfspace(
        depthIntercept - minimumProjectedDepth - depthGuard, depthSlope,
        minimumTravel, maximumTravel);
    visibleSegment = beamrtClipReflectionHalfspace(
        0.9999 - depthIntercept, -depthSlope,
        minimumTravel, maximumTravel) && visibleSegment;
    visibleSegment = beamrtClipReflectionHalfspace(
        duIntercept + (IN.uv0.x - clipViewportMin.x) * depthIntercept,
        duSlope + (IN.uv0.x - clipViewportMin.x) * depthSlope,
        minimumTravel, maximumTravel) && visibleSegment;
    visibleSegment = beamrtClipReflectionHalfspace(
        (clipViewportMax.x - IN.uv0.x) * depthIntercept - duIntercept,
        (clipViewportMax.x - IN.uv0.x) * depthSlope - duSlope,
        minimumTravel, maximumTravel) && visibleSegment;
    visibleSegment = beamrtClipReflectionHalfspace(
        dvIntercept + (IN.uv0.y - clipViewportMin.y) * depthIntercept,
        dvSlope + (IN.uv0.y - clipViewportMin.y) * depthSlope,
        minimumTravel, maximumTravel) && visibleSegment;
    visibleSegment = beamrtClipReflectionHalfspace(
        (clipViewportMax.y - IN.uv0.y) * depthIntercept - dvIntercept,
        (clipViewportMax.y - IN.uv0.y) * depthSlope - dvSlope,
        minimumTravel, maximumTravel) && visibleSegment;
    if (!visibleSegment || maximumTravel <= minimumTravel)
    {
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
        if (diagnosticMode > 0)
            return beamrtReflectionDiagnostic(diagnosticMode, 1, BEAMRT_SSR_LEFT_VIEW, 0.0, 0.0, safeThickness);
#endif
        return 0.0;
    }

    // The seed is a sampled depth at the actual biased origin (or its native
    // frustum entry). It must truly be in front; zero bias may put it exactly
    // on the receiver, so a physical forward probe supplies the next sample.
    float2 startUv = 0.0;
    float startEyeDepth = 0.0;
    if (!beamrtProjectEyeVector(
        rayOrigin + rayDirection * minimumTravel - eyePosWorld,
        IN.wsEyeRay, eyeRayDu, eyeRayDv, IN.uv0, startUv, startEyeDepth)
        || startEyeDepth < minimumProjectedDepth
        || any(startUv <= viewportMin) || any(startUv >= viewportMax))
    {
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
        if (diagnosticMode > 0)
            return beamrtReflectionDiagnostic(diagnosticMode, 1, BEAMRT_SSR_LEFT_VIEW, 0.0, 0.0, safeThickness);
#endif
        return 0.0;
    }
    float startSceneEyeDepth = beamrtSceneEyeDepth(startUv);
    bool hasFrontSample = startSceneEyeDepth < 0.9999
        && (startEyeDepth - startSceneEyeDepth) * projParams.y < 0.0;
#ifdef BEAMRT_REFLECTION_FIRST_SURFACE
    int2 startDepthPixel = clamp(int2(startUv * depthTextureSize),
        int2(0, 0), depthMaximumPixel);
    float startDepthDeltaWorld = (startEyeDepth - startSceneEyeDepth) * projParams.y;
    bool receiverDepartureAllowed = !hasFrontSample && minimumTravel == 0.0
        && startSceneEyeDepth < 0.9999
        && all(startDepthPixel == receiverDepthPixel)
        && abs(startSceneEyeDepth - decoded.w) * projParams.y <= receiverDepthTolerance
        && abs(startDepthDeltaWorld) <= receiverDepthTolerance;
    if (startSceneEyeDepth < 0.9999 && !hasFrontSample && !receiverDepartureAllowed)
    {
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
        if (diagnosticMode > 0 && diagnosticMode != 6)
            return beamrtReflectionDiagnostic(diagnosticMode, 2, BEAMRT_SSR_NO_FRONT,
                startUv, startDepthDeltaWorld, safeThickness);
#endif
        return 0.0;
    }
#endif
    float3 bestRadiance = 0.0;
    float bestConfidence = 0.0;
#ifdef BEAMRT_REFLECTION_CONVERGENCE
    float bestGeometryCategory = 0.0; // unknown/unresolved visible SSR contribution
#endif
#ifdef BEAMRT_REFLECTION_HIT_AWARE
    float bestHitMetadata = 0.0;
#endif
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
    bool diagnosticHadCrossing = false;
    int diagnosticReason = BEAMRT_SSR_WORK_END;
    float diagnosticDepthError = 0.0;
    float2 diagnosticHitUv = 0.0;
#endif

    // Owned native-derived mip-0 traversal, not the experimental linear marcher.
    {
        float2 refinedUv = 0.0;
        float refinedRayEyeDepth = 0.0, refinedSceneEyeDepth = 0.0, highTravel = 0.0, forkConfidence = 0.0;
        int failureReason = BEAMRT_SSR_INVALID_INPUT;
        if (!beamrtSssrForkTrace(IN, eyeRayDu, eyeRayDv, rayOrigin, rayDirection,
            minimumTravel, maximumTravel, lookupBudget, safeThickness,
            refinedUv, refinedRayEyeDepth, refinedSceneEyeDepth, highTravel, forkConfidence, failureReason))
        {
            if (diagnosticMode > 0)
                return beamrtReflectionDiagnostic(diagnosticMode,
                    failureReason == BEAMRT_SSR_NATIVE_VALIDATION ? 2 : 1,
                    failureReason, 0.0, 0.0, safeThickness);
            return 0.0;
        }
        float refinedDelta = (refinedRayEyeDepth - refinedSceneEyeDepth) * projParams.y;
        float2 travelPixels2 = (refinedUv - IN.uv0) / uvTexel;
        float travelConfidence = smoothstep(1.0, 2.5, length(travelPixels2));
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
        diagnosticDepthError = refinedDelta;
        diagnosticHitUv = refinedUv;
#endif
        if (refinedDelta < -0.001 || travelConfidence <= 0.001)
        {
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
            diagnosticReason = refinedDelta < -0.001
                ? BEAMRT_SSR_NEGATIVE_DEPTH : BEAMRT_SSR_SCREEN_TRAVEL;
#endif
#ifdef BEAMRT_REFLECTION_FIRST_SURFACE
            // Once a genuine crossing exists, its rejection is authoritative.
            // Small screen travel does not authorize a different later layer.
            if (diagnosticMode > 0)
                return beamrtReflectionDiagnostic(diagnosticMode, 2, diagnosticReason,
                    refinedUv, refinedDelta, safeThickness);
            return 0.0;
#else
            hasFrontSample = false;
            continue;
#endif
        }
        if (refinedDelta > safeThickness)
        {
            // A depth discontinuity is still an occluder. Do not march through
            // it and accidentally select unrelated geometry behind it.
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
            diagnosticReason = BEAMRT_SSR_THICKNESS;
            if (diagnosticMode > 0)
                return beamrtReflectionDiagnostic(diagnosticMode, 2, diagnosticReason,
                    refinedUv, refinedDelta, safeThickness);
#endif
            return 0.0;
        }

        float3 hitNormal = decodeNormalXY(tex2Dlod(prepassTex, float4(refinedUv, 0.0, 0.0)).xy);
        float facingDot = dot(hitNormal, -rayDirection);
        if (facingDot <= 0.02)
        {
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
            diagnosticReason = BEAMRT_SSR_BACKFACE;
            if (diagnosticMode > 0)
                return beamrtReflectionDiagnostic(diagnosticMode, 2, diagnosticReason,
                    refinedUv, refinedDelta, safeThickness);
#endif
            return 0.0;
        }
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
        // Acceptance is geometric. A dark source or zero edge/distance
        // confidence still represents accepted geometry in diagnostic views.
        // State/UV/error views return before any source colour fetch. Raw
        // colour alone reads the validated hit without confidence dimming.
        // Composite mode proceeds through the production radiance math.
        if (diagnosticMode > 0 && diagnosticMode != 5 && diagnosticMode != 6)
            return beamrtReflectionDiagnostic(diagnosticMode, 3, BEAMRT_SSR_ACCEPTED,
                refinedUv, refinedDelta, safeThickness);
        if (diagnosticMode == 5)
        {
            float2 diagnosticSourceUv = beamrtPrepassUvToBackbufferUv(refinedUv);
            // Exact source texel isolates colour mixing at silhouettes. Query
            // the source target itself: SSR and viewport sizes may differ.
            // Production mode zero retains its existing linear sample below.
            uint diagnosticSourceWidth;
            uint diagnosticSourceHeight;
            backBufferTexTex.GetDimensions(diagnosticSourceWidth, diagnosticSourceHeight);
            int2 diagnosticSourceSize = max(int2(diagnosticSourceWidth, diagnosticSourceHeight), int2(1, 1));
            int2 diagnosticSourcePixel = clamp(
                int2(floor(diagnosticSourceUv * float2(diagnosticSourceSize))),
                int2(0, 0), diagnosticSourceSize - 1);
            return float4(backBufferTexTex.Load(int3(diagnosticSourcePixel, 0)).rgb, 1.0);
        }
#endif

        // Depth agreement around the hit suppresses silhouettes and thin rear
        // surfaces without making them a hard binary rejection.
        float continuity = 0.0;
        float2 continuityOffsets[4] = {
            float2(uvTexel.x, 0.0), float2(-uvTexel.x, 0.0),
            float2(0.0, uvTexel.y), float2(0.0, -uvTexel.y)
        };
        [unroll]
        for (int continuityIndex = 0; continuityIndex < 4; ++continuityIndex)
        {
            float2 neighborUv = clamp(refinedUv + continuityOffsets[continuityIndex], viewportMin, viewportMax);
            float neighborDepth = beamrtSceneEyeDepth(neighborUv);
            if (neighborDepth < 0.9999)
            {
                float neighborDelta = abs(neighborDepth - refinedSceneEyeDepth) * projParams.y;
                continuity += 1.0 - smoothstep(0.05, max(0.35, safeThickness * 2.0), neighborDelta);
            }
        }
        continuity *= 0.25;

        float facingConfidence = smoothstep(0.02, 0.35, facingDot);
        float distanceConfidence = sqrt(saturate(1.0 - highTravel / maxDistance));
        float continuityConfidence = lerp(0.30, 1.0, continuity);
        float confidence = forkConfidence * beamrtEdgeConfidence(refinedUv)
            * distanceConfidence * facingConfidence * travelConfidence * continuityConfidence;
        float2 backbufferUv = beamrtPrepassUvToBackbufferUv(refinedUv);
        float3 reflectedLinear = hdrDecode(tex2Dlod(backBufferTex, float4(backbufferUv, 0.0, 0.0)).rgb);
#ifdef BEAMRT_REFLECTION_SOURCE_RECONSTRUCTION
        bool reconstructSource = reflectionSourceReconstructionEnabled > 0.5;
        if (reconstructSource)
        {
            float sourceCoverage;
            reflectedLinear = beamrtReflectionReconstructedSource(refinedUv, refinedSceneEyeDepth, sourceCoverage);
        }
#endif
#ifdef BEAMRT_REFLECTION_SAFE_RADIANCE
        // Preserve invalid-source evidence across optional source filtering;
        // min/max or neighboring color must not silently rehabilitate it.
        bool reflectionSourceFinite = beamrtReflectionRadianceIsFinite(reflectedLinear);
        if (!reflectionSourceFinite) reflectedLinear = 0.0;
#endif
#ifdef BEAMRT_REFLECTION_COLOR_FILTER
        [branch] if (reflectionColorFilterEnabled > 0.5 && useGGX && diagnosticMode == 0 && roughness > 0.04
#ifdef BEAMRT_REFLECTION_SOURCE_RECONSTRUCTION
            && !reconstructSource
#endif
            )
            reflectedLinear = beamrtReflectionFilteredSource(reflectedLinear,
                (refinedUv - rtParams0.xy) / rtParams0.zw,
                refinedSceneEyeDepth * projParams.y, roughness, highTravel);
#endif
#ifdef BEAMRT_REFLECTION_SAFE_RADIANCE
        // Keep invalid source components out of all weighted arithmetic. A
        // rejected RGB source does not invalidate an accepted geometric hit.
        reflectedLinear = reflectionSourceFinite
            ? beamrtReflectionFiniteSource(reflectedLinear) : 0.0;
#endif
        bestRadiance = max(reflectedLinear, 0.0) * confidence;
#ifdef BEAMRT_REFLECTION_GGX
        if (useGGX) bestRadiance *= reflectionThroughput;
#endif
        bestConfidence = confidence;
#ifdef BEAMRT_REFLECTION_CONVERGENCE
        bestGeometryCategory = 1.0; // includes accepted black and zero-confidence geometry
#endif
#ifdef BEAMRT_REFLECTION_HIT_AWARE
        if (useGGX && reflectionHitAwareEnabled > 0.5 && confidence > 0.0)
            bestHitMetadata = beamrtPackHitUV((refinedUv - rtParams0.xy) / rtParams0.zw);
#endif
    }

#ifdef BEAMRT_REFLECTION_SAFE_RADIANCE
    // Temporal/history color must remain representable in RGBA16F, even if
    // hit-aware tracing uses RGBA32F. Preserve alpha separately: confidence,
    // packed hit UV and convergence categories are not radiance.
    bestRadiance = beamrtReflectionSafeRadiance(bestRadiance);
#endif
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
    if (diagnosticMode > 0 && diagnosticMode != 6)
        return beamrtReflectionDiagnostic(diagnosticMode, diagnosticHadCrossing ? 2 : 1,
            diagnosticReason, diagnosticHitUv, diagnosticDepthError, safeThickness);
#endif
#ifdef BEAMRT_REFLECTION_CONVERGENCE
    if (reflectionConvergenceEnabled > 0.5 && diagnosticMode == 0)
        return float4(bestRadiance, bestGeometryCategory);
#endif
#ifdef BEAMRT_REFLECTION_HIT_AWARE
    if (useGGX && reflectionHitAwareEnabled > 0.5)
        return float4(bestRadiance, bestHitMetadata);
#endif
    return float4(bestRadiance, bestConfidence);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
