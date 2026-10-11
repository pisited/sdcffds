#ifndef BEAMRT_LIGHTING_COMPOSE_V052_H_HLSL
#define BEAMRT_LIGHTING_COMPOSE_V052_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"

uniform_sampler2D(backBufferTex, 0);
uniform_sampler2D(temporalGITex, 1);
uniform_sampler2D(prepassTex, 2);
uniform_sampler2D(prepassDepthTex, 3);
#ifdef BEAMRT_CONFIDENCE_AWARE_COMPOSE
uniform_sampler2D(giMomentsTex, 4);
#endif
#ifdef BEAMRT_SIX_INPUT_COMPOSE
uniform_sampler2D(receiverResponseTex, 5);
#elif defined(BEAMRT_RECEIVER_REFLECTANCE)
uniform_sampler2D(receiverLightInfoTex, 5);
uniform_sampler2D(receiverMaterialSpecTex, 6);
#endif
#if defined(BEAMRT_LIGHTING_STAGE_DIAGNOSTICS) && !defined(BEAMRT_RAW_DIAGNOSTIC_PRIMARY_INPUT) && !defined(BEAMRT_SIX_INPUT_COMPOSE)
uniform_sampler2D(rawGITex, 7);
#endif

cbuffer perDraw : register(b0)
{
    uniform float giStrength;
    uniform float contactShadowStrength;
    uniform float bounceSaturation;
    uniform float giExposure;
    uniform float giShadowFocus;
    uniform float giReceiverTint;
    uniform float giContrast;
    uniform float giEnergyLimit;
    uniform float giHighlightRolloff;
    uniform float giRenderScale;
#ifdef BEAMRT_LIGHTING_STAGE_DIAGNOSTICS
    uniform float giLightingDiagnostic;
    uniform float giLightingDiagnosticGain;
#endif
#ifdef BEAMRT_RAY_HIT_DIAGNOSTIC
    uniform float giTraceDebugMode;
#endif
    uniform float2 oneOverTargetSize;
    uniform float2 targetSize;
    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#endif // BEAMRT_LIGHTING_COMPOSE_V052_H_HLSL
