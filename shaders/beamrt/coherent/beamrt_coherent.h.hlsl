#ifndef BEAMRT_COH_SSR_EFFECT_HEADER
#define BEAMRT_COH_SSR_EFFECT_HEADER

#define BEAMRT_COH_WATER_MAX_PLANES 4

#include "shaders/common/bng.hlsl"
#include "shaders/common/postFx/postFx.h.hlsl"

#if defined(BEAMRT_COH_SSR_PASS) && BEAMRT_COH_SSR_PASS == 2
uniform_sampler2D(sourceTex, 2);
#else
uniform_sampler2D(sourceTex, 0);
#endif
#if defined(BEAMRT_COH_SSR_PASS) && (BEAMRT_COH_SSR_PASS == 5 || BEAMRT_COH_SSR_PASS == 7 || BEAMRT_COH_SSR_PASS == 9 || BEAMRT_COH_SSR_PASS == 15)
#define prepassTex sourceTex
#define prepassTexTex sourceTexTex
#define prepassTex_sampler_ sourceTex_sampler_
#else
uniform_sampler2D(prepassTex, 1);
#endif
#if defined(BEAMRT_COH_SSR_PASS) && (BEAMRT_COH_SSR_PASS == 5 || BEAMRT_COH_SSR_PASS == 7 || BEAMRT_COH_SSR_PASS == 9 || BEAMRT_COH_SSR_PASS == 15)
#define prepassDepthTex sourceTex
#define prepassDepthTexTex sourceTexTex
#define prepassDepthTex_sampler_ sourceTex_sampler_
#elif defined(BEAMRT_COH_SSR_PASS) && BEAMRT_COH_SSR_PASS == 2
uniform_sampler2D(prepassDepthTex, 0);
#else
uniform_sampler2D(prepassDepthTex, 2);
#endif
#if defined(BEAMRT_COH_SSR_PASS) && (BEAMRT_COH_SSR_PASS == 11 || BEAMRT_COH_SSR_PASS == 5 || BEAMRT_COH_SSR_PASS == 7 || BEAMRT_COH_SSR_PASS == 8 || BEAMRT_COH_SSR_PASS == 9 || BEAMRT_COH_SSR_PASS == 15)
#define auxTex sourceTex
#define auxTexTex sourceTexTex
#define auxTex_sampler_ sourceTex_sampler_
#else
uniform_sampler2D(auxTex, 3);
#endif
#if defined(BEAMRT_COH_SSR_PASS) && (BEAMRT_COH_SSR_PASS == 11 || BEAMRT_COH_SSR_PASS == 5 || BEAMRT_COH_SSR_PASS == 7 || BEAMRT_COH_SSR_PASS == 8 || BEAMRT_COH_SSR_PASS == 9 || BEAMRT_COH_SSR_PASS == 10 || BEAMRT_COH_SSR_PASS == 15)
#define debugTex sourceTex
#define debugTexTex sourceTexTex
#define debugTex_sampler_ sourceTex_sampler_
#else
uniform_sampler2D(debugTex, 4);
#endif
#if defined(BEAMRT_COH_SSR_PASS) && (BEAMRT_COH_SSR_PASS == 11 || BEAMRT_COH_SSR_PASS == 5 || BEAMRT_COH_SSR_PASS == 7 || BEAMRT_COH_SSR_PASS == 8 || BEAMRT_COH_SSR_PASS == 9 || BEAMRT_COH_SSR_PASS == 10 || BEAMRT_COH_SSR_PASS == 15)
#define terrainTex sourceTex
#define terrainTexTex sourceTexTex
#define terrainTex_sampler_ sourceTex_sampler_
#else
uniform_sampler2D(terrainTex, 5);
#endif

cbuffer perDraw : register(b0)
{
    uniform float4 rtParams5;
    uniform float uAmount;
    uniform float uSamplingMode;
    uniform float uReferenceTrace;
    uniform float uRoughStability;
    uniform float uIntensity;

    uniform float uMaxDistance;
    uniform float uTraceQuality;
    uniform float uThicknessTexels;
    uniform float uNormalBias;
    uniform float uRayStartOffset;

    uniform float uRoughnessStart;
    uniform float uRoughnessEnd;
    uniform float uRoughnessPower;
    uniform float uFresnelPower;
    uniform float uFresnelStrength;
    uniform float uNativeMaterialResponse;
    uniform float uFacingFade;

    uniform float uEdgeFadePixels;
    uniform float uReflectionEdgeFade;
    uniform float uSkyFadeStart;
    uniform float uSkyFadeEnd;
    uniform float uDistanceFadeStart;
    uniform float uDistanceFadeEnd;

    uniform float uBackfaceFade;
    uniform float uScreenJitter;
    uniform float uJitterTemporalRate;

    uniform float uUnifiedTemporal;
    uniform float uHistoryInterleave;
    uniform float uTemporalStrength;
    uniform float uAdaptiveDenoising;
    uniform float uHistoryGeometryValid;
    uniform float uGeometryReconstruction;
    uniform float uReusePrefiltered;
    uniform float uReuseGuides;
    uniform float uTemporalClamp;
    uniform float uRoughnessAdaptiveDenoise;
    uniform float uTraceClass;
    uniform float uAdaptiveResolution;
    uniform float uAdaptiveRoughStart;
    uniform float uAdaptiveRoughEnd;
    uniform float2 uRoughTraceJitterUV;
    uniform float uThicknessResolutionY;

    uniform float uFireflySuppression;
    uniform float uStochasticReuse;
    uniform float uOverhangFill;
    uniform float uOverhangBrightness;
    uniform float uOverhangBounce;
    uniform float uStochasticSSR;
    uniform float uStochasticBias;
    uniform float uStochasticTemporalRate;
    uniform float uStochasticRayCount;
    uniform float uHiZMaxLevel;
    uniform float2 uTraceJitterUV;
    uniform float2 uCameraJitterUV;
    uniform float uFilteredColor;
    uniform float uColorMipScale;

    uniform float3 uPrevEyePosWorld;
    uniform float uTemporalHistoryValid;
    uniform float uTemporalReprojectionValid;
    uniform float3 uPrevCameraRight;
    uniform float uPrevTanHalfFovX;
    uniform float3 uPrevCameraForward;
    uniform float uPrevTanHalfFovY;
    uniform float3 uPrevCameraUp;
    uniform float3 uCameraRight;    uniform float uTanHalfFovXCur;
    uniform float3 uCameraUp;       uniform float uTanHalfFovYCur;
    uniform float3 uCameraForward;  uniform float uProjectionValid;
    uniform float uScreenMappingFromEngine;

    uniform float uVelocityValid;
    uniform float uCameraHistoryValid;

    uniform float4 uMotionOptions;
    uniform float4 uVehicleCenter;
    uniform float4 uVehicleAxisX;
    uniform float4 uVehicleAxisY;
    uniform float4 uVehicleAxisZ;
    uniform float4 uVehicleHalf;
    uniform float4 uVehiclePrevCenter;
    uniform float4 uVehiclePrevAxisX;
    uniform float4 uVehiclePrevAxisY;
    uniform float4 uVehiclePrevAxisZ;

    uniform float uTemporalMotionRejection;
    uniform float uTemporalMotionRejectionRot;

    uniform float uWetness;
    uniform float uWetUpDotStart;
    uniform float uWetUpDotEnd;
    uniform float uWetRoughnessEnd;

    uniform float uWaterSSR;
    uniform float uWaterShaderData;
    uniform float uWaterShaderDataAvailable;
    uniform float uWaterSSRStrength;
    uniform float4 uWaterDeepColor;
    uniform float uWaterColorStrength;

    uniform float uWaterWaveStrength;
    uniform float uWaterWaveScale;
    uniform float uWaterWaveDistanceFade;
    uniform float uWaterRippleSpeed;
    uniform float uWaterOverallMag;
    uniform float4 uWaterRippleMag;
    uniform float4 uWaterWave0;
    uniform float4 uWaterWave1;
    uniform float4 uWaterWave2;

    uniform float uWaterSSRRoughness;
    uniform float uWaterSSRFlatNormal;
    uniform float uWaterAngleMin;
    uniform float uWaterAngleStart;
    uniform float uWaterAngleEnd;
    uniform float uWaterAnglePower;
    uniform float uWaterPlaneFadeMeters;
    uniform float uWaterSurfaceDepthBias;
    uniform float uWaterFarTraceDistance;
    uniform float uWaterPlaneCount;

    uniform float4 uWaterPlane0;
    uniform float4 uWaterPlane1;
    uniform float4 uWaterPlane2;
    uniform float4 uWaterPlane3;

    uniform float uRiverMaskEnable;
    uniform float uRiverWorldSize;
    uniform float uRiverHeightMin;
    uniform float uRiverHeightRange;
    uniform float2 uRiverOriginXY;
    uniform float uRiverReferenceHeight;
    uniform float uRiverFlipY;

    uniform float uResolveMode;
    uniform float uHighRoughnessSuppression;
    uniform float uResolveRadius;
    uniform float uResolveDepthSigma;
    uniform float uResolveNormalPower;

    uniform float uFrame;
    uniform float uTime;
    uniform float uPass;
    uniform float uDebugView;
    uniform float2 uResolution;
    uniform float uFogTransport;
    float _tfxFogTransportPadding;
    uniform float3 eyePosWorld;
    float _tfxEyePosWorldPadding;

    uniform float3 fogData;
    float _tfxFogDataPadding;

    uniform float uPuddleStrength;
    uniform float uPuddleScale;
    uniform float uPuddleEdgeLo;
    uniform float uPuddleEdgeHi;
    uniform float uPuddleUpDotStart;
    uniform float uPuddleUpDotEnd;
    uniform float uPuddleRoughness;
    uniform float uPuddleRippleScale;
    uniform float uPuddleRippleSpeed;
    uniform float uPuddleRippleStrength;
    uniform float uPuddleDarken;
    uniform float uPuddleFadeStart;
    uniform float uPuddleFadeEnd;
    uniform float uPuddleReflectivity;
    uniform float uPuddleWaterCull;
    uniform float uPuddleEdgeSoftness;
    uniform float uPuddleFresnel;
    uniform float uPuddleEnvironmentStrength;

    uniform float uTerrainMaskEnable;
    uniform float uTerrainMaskStrength;
    uniform float2 uTerrainOriginXY;
    uniform float uTerrainWorldSize;
    uniform float uTerrainFlipY;

    uniform float uSkyReflectionFallback;
    uniform float uWaterSkyFallback;
    uniform float uSkyReflectionBrightness;
    uniform float uSkySaturation;
    uniform float uSkyBeforeTemporal;
    uniform float uSkyScreenSpace;
    uniform float uSkyScreenBrightness;
    uniform float uSkyScreenMinDistance;
    uniform float uSkyDirectionality;
    uniform float uSkySunBoost;

    uniform float uLightInfoValid;
    uniform float uLightExposureScale;
    uniform float uSkyLightExposure;
    uniform float uSkyLightTint;

    uniform float3 sunIrradiance;
    float _tfxSunIrradiancePadding;

    uniform float3 sunDirection;
    float _tfxSunDirectionPadding;
    uniform float3 sunRadiance;
    float _tfxSunRadiancePadding;

    uniform float4 uEngineInputs;
    uniform float uEngineAOOcclusion;
    uniform float uEngineAOOpenLevel;
    uniform float uPixelRebuild;
    uniform float uTraceFootprintAA;
    uniform float uSurfaceDetail;
    uniform float uHdrComposite;

    uniform float uVirtualReprojection;
    uniform float uVirtualRoughStart;
    uniform float uVirtualRoughEnd;
    uniform float uVirtualMotionScale;
    uniform float uVirtualParallaxScale;

    uniform float4 ambientSH9[9];

    uniform float uWaterNoiseRipple;
    uniform float uWaterNoiseRippleScale;

    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#endif
