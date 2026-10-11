#ifndef BEAMRT_GI_TRACE_V065_H_HLSL
#define BEAMRT_GI_TRACE_V065_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"

uniform_sampler2D(prepassTex, 0);
uniform_sampler2D(prepassDepthTex, 1);
uniform_sampler2D(backBufferTex, 2);
#ifdef BEAMRT_SIX_INPUT_BINDINGS
uniform_sampler2D(lightInfoTex, 3);
uniform_sampler2D(auxiliaryTex, 4);
uniform_sampler2D(materialSpecTex, 5);
#else
#ifdef BEAMRT_DIRECT_DIFFUSE_SOURCE
#ifdef BEAMRT_LIGHTINFO_SLOT3
uniform_sampler2D(lightInfoTex, 3);
uniform_sampler2D(surfelRadianceTex, 4);
#else
uniform_sampler2D(surfelRadianceTex, 3);
uniform_sampler2D(lightInfoTex, 4);
#endif
uniform_sampler2D(materialSpecTex, 5);
#else
uniform_sampler2D(surfelRadianceTex, 3);
#endif
#ifdef BEAMRT_PTGI_CLEAN_SOURCE
uniform_sampler2D(cleanRadianceTex, 6);
#endif
#ifdef BEAMRT_EXPERIMENTAL_TRANSPORT
uniform_sampler2D(previousGITex, 7);
uniform_sampler2D(maskedEmissiveTex, 8);
#ifdef BEAMRT_BLUE_NOISE
uniform_sampler2D(blueNoiseTex, 9);
#ifdef BEAMRT_STBN_ATLAS
uniform_sampler2D(stbnNoiseTex, 10);
#endif
#endif
#ifdef BEAMRT_SECOND_BOUNCE_DEPTH_MOMENTS
uniform_sampler2D(historyMomentsTex, 11);
#ifdef BEAMRT_SECOND_BOUNCE_REPROJECTION
uniform_sampler2D(velocityTex, 12);
#endif
#endif
#endif
#endif // BEAMRT_SIX_INPUT_BINDINGS

cbuffer perDraw : register(b0)
{
    uniform float3 eyePosWorld;
    uniform float rayStepSize;
    uniform float rayThickness;
    uniform float rayNormalBias;
    uniform float rayMaxSteps;
    uniform float giClamp;
    uniform float giFrameIndex;
    uniform float giCellSize;
    uniform float giPathCount;
    uniform float giSourceMode;
    uniform float worldGIStrength;
    uniform float worldLeakSuppression;
    uniform float radianceCleanup;
    uniform float specularReject;
#ifdef BEAMRT_DIRECT_DIFFUSE_SOURCE
    uniform float radianceSourceMode;
    uniform float radianceChromaStrength;
    uniform float retroReject;
#endif
#ifdef BEAMRT_PTGI_CLEAN_SOURCE
    uniform float ptgiRadianceSourceMode;
#endif
#ifdef BEAMRT_EXPERIMENTAL_TRANSPORT
    uniform float giEstimatorMode;
    uniform float giLocalization;
    uniform float giSecondBounceStrength;
    uniform float giHistoryValid;
#ifdef BEAMRT_SIX_INPUT_BINDINGS
    uniform float2 giAuxImageSize;
#endif
    uniform float giEmissiveBoost;
#ifdef BEAMRT_BLUE_NOISE
    uniform float giBlueNoiseStrength;
#ifdef BEAMRT_STBN_ATLAS
    uniform float giBlueNoiseMode;
#endif
#endif
#ifdef BEAMRT_ADAPTIVE_RAY_BUDGET
    uniform float giRayReach;
    uniform float giRearRayReach;
#endif
#ifdef BEAMRT_REFINED_HITS
    uniform float giHitRefinementSteps;
    uniform float giTraceDebugMode;
#ifdef BEAMRT_SCREEN_DDA
    uniform float giMarcherMode;
    uniform float giScreenStride;
#ifdef BEAMRT_BOUNDED_SCREEN_DDA
    uniform float giScreenBudgetSteps;
    uniform float giScreenBudgetPaths;
#endif
    uniform float2 targetSize;
#endif
#ifdef BEAMRT_HIT_VALIDATION
    uniform float giHitValidationStrength;
    uniform float giMinHitTravelPixels;
#endif
#ifdef BEAMRT_CANDIDATE_CONTINUATION
    uniform float giCandidateContinuation;
    uniform float giCandidateRetryCount;
#endif
#ifdef BEAMRT_EMISSIVE_SEPARATION
    uniform float giEmissiveSeparation;
#endif
#endif
#endif
    uniform float surfelVisibilityTolerance;
    uniform float surfelCount;
    uniform float surfelMaxDistance;
    uniform float surfelCacheBlend;
    uniform float surfelCacheReset;
    uniform float4 surfelPositionRadius0;
    uniform float4 surfelNormalSource0;
    uniform float4 surfelPositionRadius1;
    uniform float4 surfelNormalSource1;
    uniform float4 surfelPositionRadius2;
    uniform float4 surfelNormalSource2;
    uniform float4 surfelPositionRadius3;
    uniform float4 surfelNormalSource3;
    uniform float4 surfelPositionRadius4;
    uniform float4 surfelNormalSource4;
    uniform float4 surfelPositionRadius5;
    uniform float4 surfelNormalSource5;
    uniform float4 surfelPositionRadius6;
    uniform float4 surfelNormalSource6;
    uniform float4 surfelPositionRadius7;
    uniform float4 surfelNormalSource7;
    uniform float4 surfelPositionRadius8;
    uniform float4 surfelNormalSource8;
    uniform float4 surfelPositionRadius9;
    uniform float4 surfelNormalSource9;
    uniform float4 surfelPositionRadius10;
    uniform float4 surfelNormalSource10;
    uniform float4 surfelPositionRadius11;
    uniform float4 surfelNormalSource11;
    uniform float4 surfelPositionRadius12;
    uniform float4 surfelNormalSource12;
    uniform float4 surfelPositionRadius13;
    uniform float4 surfelNormalSource13;
    uniform float4 surfelPositionRadius14;
    uniform float4 surfelNormalSource14;
    uniform float4 surfelPositionRadius15;
    uniform float4 surfelNormalSource15;
    uniform float4 surfelPositionRadius16;
    uniform float4 surfelNormalSource16;
    uniform float4 surfelPositionRadius17;
    uniform float4 surfelNormalSource17;
    uniform float4 surfelPositionRadius18;
    uniform float4 surfelNormalSource18;
    uniform float4 surfelPositionRadius19;
    uniform float4 surfelNormalSource19;
    uniform float4 surfelPositionRadius20;
    uniform float4 surfelNormalSource20;
    uniform float4 surfelPositionRadius21;
    uniform float4 surfelNormalSource21;
    uniform float4 surfelPositionRadius22;
    uniform float4 surfelNormalSource22;
    uniform float4 surfelPositionRadius23;
    uniform float4 surfelNormalSource23;
    uniform float4 surfelPositionRadius24;
    uniform float4 surfelNormalSource24;
    uniform float4 surfelPositionRadius25;
    uniform float4 surfelNormalSource25;
    uniform float4 surfelPositionRadius26;
    uniform float4 surfelNormalSource26;
    uniform float4 surfelPositionRadius27;
    uniform float4 surfelNormalSource27;
    uniform float4 surfelPositionRadius28;
    uniform float4 surfelNormalSource28;
    uniform float4 surfelPositionRadius29;
    uniform float4 surfelNormalSource29;
    uniform float4 surfelPositionRadius30;
    uniform float4 surfelNormalSource30;
    uniform float4 surfelPositionRadius31;
    uniform float4 surfelNormalSource31;
#ifdef BEAMRT_SCENE_VISIBILITY_GI
    // Guarded: only GI shader v082 adds these declarations. Older presets
    // retain exactly their historical constant layout and compiled behavior.
    uniform float sceneVisibilityEnabled;
    uniform float sceneVisibilityTriangleCount;
    uniform float4 sceneVisTri0A;
    uniform float4 sceneVisTri0B;
    uniform float4 sceneVisTri0C;
    uniform float4 sceneVisTri1A;
    uniform float4 sceneVisTri1B;
    uniform float4 sceneVisTri1C;
    uniform float4 sceneVisTri2A;
    uniform float4 sceneVisTri2B;
    uniform float4 sceneVisTri2C;
    uniform float4 sceneVisTri3A;
    uniform float4 sceneVisTri3B;
    uniform float4 sceneVisTri3C;
    uniform float4 sceneVisTri4A;
    uniform float4 sceneVisTri4B;
    uniform float4 sceneVisTri4C;
    uniform float4 sceneVisTri5A;
    uniform float4 sceneVisTri5B;
    uniform float4 sceneVisTri5C;
    uniform float4 sceneVisTri6A;
    uniform float4 sceneVisTri6B;
    uniform float4 sceneVisTri6C;
    uniform float4 sceneVisTri7A;
    uniform float4 sceneVisTri7B;
    uniform float4 sceneVisTri7C;
    uniform float4 sceneVisTri8A;
    uniform float4 sceneVisTri8B;
    uniform float4 sceneVisTri8C;
    uniform float4 sceneVisTri9A;
    uniform float4 sceneVisTri9B;
    uniform float4 sceneVisTri9C;
    uniform float4 sceneVisTri10A;
    uniform float4 sceneVisTri10B;
    uniform float4 sceneVisTri10C;
    uniform float4 sceneVisTri11A;
    uniform float4 sceneVisTri11B;
    uniform float4 sceneVisTri11C;
#endif
    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#ifdef BEAMRT_SIX_INPUT_BINDINGS
// Each panel is copied without color encoding. The first two panels use GI
// resolution; noise and surfel panels retain their original integer pixels.
int2 beamrtAuxScenePixel(float2 sceneUv)
{
    float2 viewportUv = (sceneUv - rtParams0.xy) / rtParams0.zw;
    return clamp((int2)floor(viewportUv * giAuxImageSize), int2(0, 0),
        max((int2)giAuxImageSize - 1, int2(0, 0)));
}

float4 beamrtAuxPreviousGI(float2 sceneUv)
{
    return auxiliaryTexTex.Load(int3(beamrtAuxScenePixel(sceneUv), 0));
}

float2 beamrtAuxVelocity(float2 sceneUv)
{
    int2 pixel = beamrtAuxScenePixel(sceneUv);
    pixel.y += (int)giAuxImageSize.y;
    return auxiliaryTexTex.Load(int3(pixel, 0)).xy;
}

float2 beamrtAuxNativeNoise(float2 noiseUv)
{
    int2 pixel = clamp((int2)floor(noiseUv * 128.0), int2(0, 0), int2(127, 127));
    pixel += int2(1024, 2 * (int)giAuxImageSize.y);
    return auxiliaryTexTex.Load(int3(pixel, 0)).rg;
}

float2 beamrtAuxSTBN(float2 noiseUv)
{
    int2 pixel = clamp((int2)floor(noiseUv * 1024.0), int2(0, 0), int2(1023, 1023));
    pixel.y += 2 * (int)giAuxImageSize.y;
    return auxiliaryTexTex.Load(int3(pixel, 0)).rg;
}

float4 beamrtAuxSurfel(float2 cacheUv)
{
    int2 pixel = clamp((int2)floor(cacheUv * float2(32.0, 4.0)), int2(0, 0), int2(31, 3));
    pixel.y += 2 * (int)giAuxImageSize.y + 1024;
    return auxiliaryTexTex.Load(int3(pixel, 0));
}
#endif

#endif // BEAMRT_GI_TRACE_V065_H_HLSL
