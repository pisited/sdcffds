#define BEAMRT_DIRECT_DIFFUSE_SOURCE 1
#define BEAMRT_RADIANCE_CLEANUP_V056 1
#define BEAMRT_LIGHTINFO_SLOT3 1
#define BEAMRT_PTGI_CLEAN_SOURCE 1
#include "beamrtGITrace_v051.h.hlsl"
#include "beamrtRadianceCleanup_v056.h.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float3 beamrtSelectedSourceRadiance(float2 prepassUv, float2 backbufferUv)
{
    float3 selectedRadiance = beamrtDiffuseLikeRadiance(prepassUv, backbufferUv);
    if (ptgiRadianceSourceMode > 0.5)
    {
        selectedRadiance = max(tex2Dlod(cleanRadianceTex, float4(backbufferUv, 0.0, 0.0)).rgb, 0.0);
    }
    return selectedRadiance;
}

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
    if (projectedDepth <= 0.000001)
    {
        projectedUv = 0.0;
        return false;
    }

    projectedUv = currentUv + float2(weightedDu, weightedDv) / projectedDepth;
    return true;
}

void beamrtGetSurfel(int index, out float3 position, out float3 normal)
{
    float4 positions[32] = {
        surfelPositionRadius0, surfelPositionRadius1, surfelPositionRadius2, surfelPositionRadius3,
        surfelPositionRadius4, surfelPositionRadius5, surfelPositionRadius6, surfelPositionRadius7,
        surfelPositionRadius8, surfelPositionRadius9, surfelPositionRadius10, surfelPositionRadius11,
        surfelPositionRadius12, surfelPositionRadius13, surfelPositionRadius14, surfelPositionRadius15,
        surfelPositionRadius16, surfelPositionRadius17, surfelPositionRadius18, surfelPositionRadius19,
        surfelPositionRadius20, surfelPositionRadius21, surfelPositionRadius22, surfelPositionRadius23,
        surfelPositionRadius24, surfelPositionRadius25, surfelPositionRadius26, surfelPositionRadius27,
        surfelPositionRadius28, surfelPositionRadius29, surfelPositionRadius30, surfelPositionRadius31
    };
    float4 normals[32] = {
        surfelNormalSource0, surfelNormalSource1, surfelNormalSource2, surfelNormalSource3,
        surfelNormalSource4, surfelNormalSource5, surfelNormalSource6, surfelNormalSource7,
        surfelNormalSource8, surfelNormalSource9, surfelNormalSource10, surfelNormalSource11,
        surfelNormalSource12, surfelNormalSource13, surfelNormalSource14, surfelNormalSource15,
        surfelNormalSource16, surfelNormalSource17, surfelNormalSource18, surfelNormalSource19,
        surfelNormalSource20, surfelNormalSource21, surfelNormalSource22, surfelNormalSource23,
        surfelNormalSource24, surfelNormalSource25, surfelNormalSource26, surfelNormalSource27,
        surfelNormalSource28, surfelNormalSource29, surfelNormalSource30, surfelNormalSource31
    };
    position = positions[index].xyz;
    normal = normalize(normals[index].xyz);
}

float2 beamrtPrepassUvToBackbufferUv(float2 prepassUv)
{
    float2 viewportUv = (prepassUv - rtParams0.xy) / rtParams0.zw;
    return viewportCoordToRenderTarget(viewportUv, rtParams2);
}

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    int surfelIndex = clamp((int)IN.hpos.x, 0, 31);
    float2 cacheUv = float2(((float)surfelIndex + 0.5) / 32.0, 0.5);
    float4 previous = tex2Dlod(surfelRadianceTex, float4(cacheUv, 0.0, 0.0));

    if (surfelCacheReset > 0.5 || surfelIndex >= (int)clamp(surfelCount, 0.0, 32.0))
    {
        return 0.0;
    }

    float uvDx = ddx(IN.uv0.x);
    float uvDy = ddy(IN.uv0.y);
    if (abs(uvDx) < 0.00000001 || abs(uvDy) < 0.00000001)
    {
        return previous;
    }

    float3 surfelPosition;
    float3 surfelNormal;
    beamrtGetSurfel(surfelIndex, surfelPosition, surfelNormal);

    float3 eyeRayDu = ddx(IN.wsEyeRay) / uvDx;
    float3 eyeRayDv = ddy(IN.wsEyeRay) / uvDy;
    float2 surfelUv;
    float surfelEyeDepth;
    if (!beamrtProjectEyeVector(
        surfelPosition - eyePosWorld,
        IN.wsEyeRay,
        eyeRayDu,
        eyeRayDv,
        IN.uv0,
        surfelUv,
        surfelEyeDepth))
    {
        return previous;
    }

    float2 viewportOtherCorner = rtParams0.xy + rtParams0.zw;
    float2 viewportMin = min(rtParams0.xy, viewportOtherCorner);
    float2 viewportMax = max(rtParams0.xy, viewportOtherCorner);
    if (surfelEyeDepth >= 0.9999 || any(surfelUv <= viewportMin) || any(surfelUv >= viewportMax))
    {
        return previous;
    }

    float sceneNdcDepth = tex2Dlod(prepassDepthTex, float4(surfelUv, 0.0, 0.0)).r;
    float sceneRealDepth = ndcToRealDepth(sceneNdcDepth, projParams.zw);
    float sceneEyeDepth = realToEyeLinearDepth(sceneRealDepth, projParams);
    if (sceneEyeDepth >= 0.9999)
    {
        return previous;
    }

    float tolerance = max(surfelVisibilityTolerance, 0.05);
    float depthDeltaWorld = abs(surfelEyeDepth - sceneEyeDepth) * projParams.y;
    float3 visibleNormal = decodeNormalXY(tex2Dlod(prepassTex, float4(surfelUv, 0.0, 0.0)).xy);
    if (depthDeltaWorld > tolerance || dot(visibleNormal, surfelNormal) <= 0.2)
    {
        return previous;
    }

    float2 backbufferUv = beamrtPrepassUvToBackbufferUv(surfelUv);
    // Store the same diffuse-like estimator used by live screen-space GI.
    // This prevents one captured reflection highlight from persisting as an
    // omnidirectional glowing surfel on subsequent frames.
    float3 observed = beamrtSelectedSourceRadiance(surfelUv, backbufferUv);
    float currentWeight = previous.a > 0.5 ? saturate(surfelCacheBlend) : 1.0;
    return float4(lerp(previous.rgb, observed, currentWeight), 1.0);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
