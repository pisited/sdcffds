#ifndef BEAMRT_COH_SSR_PROJECTION_HLSL
#define BEAMRT_COH_SSR_PROJECTION_HLSL

bool IsInvalidDepth(float rawDepth, float realDepth, float eyeDepth01)
{
    return rawDepth >= 0.999999 || realDepth <= 0.0001 || eyeDepth01 <= 0.000001 || eyeDepth01 >= 0.999999;
}

bool IsInvalidSceneDepth(float rawDepth, float realDepth)
{
    return rawDepth >= 0.999999 || realDepth <= 0.0001;
}

float3 ReconstructWorldPosition(PFXVertToPix IN, float eyeDepth01)
{
    return eyePosWorld + IN.wsEyeRay * eyeDepth01;
}

float2 BrtcScaleReflectionTranslation(float2 surfaceUV, float2 reflectionUV)
{
    return lerp(surfaceUV,reflectionUV,max(uVirtualParallaxScale,0.0));
}

struct SSRProjectionBasis
{
    float2 centerUV;
    float2 screenCenter;
};

SSRProjectionBasis BuildProjectionBasis(PFXVertToPix IN, float2 centerUV, float3 receiverPoint)
{
    SSRProjectionBasis basis;
    basis.centerUV = centerUV;
    basis.screenCenter = BrtcScreenCenterFromPoint(receiverPoint, centerUV);
#if defined(__SHADER_TARGET_MAJOR) && __SHADER_TARGET_MAJOR >= 6
    basis.screenCenter = WaveReadLaneFirst(basis.screenCenter);
#endif
    return basis;
}

float BrtcEyeDepth01(float3 worldPos, float4 projectionParams)
{
    return dot(worldPos - eyePosWorld, uCameraForward) / max(projectionParams.y, 1e-4);
}

float2 ProjectWorldToUVFast(SSRProjectionBasis basis, float3 worldPos, out float projectedEyeDepth01, out float confidence)
{
    float3 v = worldPos - eyePosWorld;

    float zReal = dot(v, uCameraForward);
    projectedEyeDepth01 = zReal / max(projParams.y, 1e-4);

    if (projectedEyeDepth01 <= 0.000001)
    {
        confidence = 0.0;
        return float2(-10.0, -10.0);
    }

    float2 exactUV = BrtcScreenUVMapped(v, zReal, basis.screenCenter, float2(1.0, 1.0));

    float2 edgePx = min(exactUV, 1.0 - exactUV) * uResolution;
    confidence = saturate(min(edgePx.x, edgePx.y));
    return exactUV;
}

float EdgeFade(float2 uv)
{
    if (uEdgeFadePixels <= 0.001)
        return 1.0;

    float2 edgePx = min(uv, 1.0 - uv) * uResolution;
    float e = saturate(min(edgePx.x, edgePx.y) / max(uEdgeFadePixels, 0.001));
    return smoothstep(0.0, 1.0, e);
}

float DistanceFade(float distMeters)
{
    float fadeStart = min(uDistanceFadeStart, uDistanceFadeEnd - 0.001);
    float fadeEnd = max(uDistanceFadeEnd, fadeStart + 0.001);
    return 1.0 - smoothstep(fadeStart, fadeEnd, distMeters);
}

float RoughnessMask(float roughness, float3 normalWS, out float effectiveRoughness)
{
    float horizontalMask = smoothstep(uWetUpDotStart, uWetUpDotEnd, normalWS.z);
    float roughnessEligible = 1.0 - smoothstep(max(uWetRoughnessEnd - 0.10, 0.0), 1.0, roughness);

    float wetMask = horizontalMask * roughnessEligible * saturate(uWetness);

    effectiveRoughness = roughness;
    effectiveRoughness = lerp(effectiveRoughness, min(effectiveRoughness, max(0.035, roughness * 0.50)), wetMask);
    effectiveRoughness = max(effectiveRoughness, 0.004);

    float glossyMask = 1.0 - smoothstep(uRoughnessStart, uRoughnessEnd, effectiveRoughness);
    glossyMask = pow(saturate(glossyMask), max(uRoughnessPower, 0.001));

    float highRoughDampen = 1.0 - smoothstep(0.70, 0.98, effectiveRoughness);
    glossyMask *= lerp(1.0, highRoughDampen, saturate(uHighRoughnessSuppression));

    return saturate(max(glossyMask, wetMask));
}

float BrtcAdaptiveGloss(float roughness, float3 normalWS, bool water)
{
    if (water)
        return 1.0;
    float effectiveRoughness;
    RoughnessMask(roughness, normalWS, effectiveRoughness);
    return 1.0 - smoothstep(uAdaptiveRoughStart, max(uAdaptiveRoughEnd, uAdaptiveRoughStart + 0.001), effectiveRoughness);
}

static const float BEAMRT_COH_NOT_TRACED = -1.0;

float FresnelMask(float3 viewToSurfaceDir, float3 normalWS)
{
    float3 surfaceToEye = normalize(-viewToSurfaceDir);
    float ndv = saturate(dot(normalWS, surfaceToEye));
    float fresnel = pow(1.0 - ndv, max(uFresnelPower, 0.001));
    return saturate(lerp(1.0, fresnel, saturate(uFresnelStrength)));
}

float BrtcOrdinaryFresnelMask(float3 viewToSurfaceDir, float3 normalWS)
{
    // Store unweighted incident reflection in history. Apply native RGB F0
    // once at the final receiver, not once per ray and again after denoising.
    return uNativeMaterialResponse > 0.5 ? 1.0 : FresnelMask(viewToSurfaceDir, normalWS);
}

float BrtcPuddleFresnelMask(float3 viewToSurfaceDir, float3 normalWS)
{
    float3 surfaceToEye = normalize(-viewToSurfaceDir);
    float NoV = saturate(dot(normalWS, surfaceToEye));
    float control = saturate(uPuddleFresnel);
    float faceOnResponse = lerp(1.0, 0.35, control);
    float grazing = pow(1.0 - NoV, 5.0);
    return saturate(lerp(faceOnResponse, 1.0, grazing));
}

float FacingFade(float3 reflectDirWS, float3 normalWS)
{
    float facing = saturate(dot(reflectDirWS, normalWS));
    return smoothstep(0.0, max(uFacingFade, 0.0001), facing);
}

#endif
