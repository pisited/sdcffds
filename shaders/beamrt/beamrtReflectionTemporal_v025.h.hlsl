#ifndef BEAMRT_REFLECTION_TEMPORAL_V025_H_HLSL
#define BEAMRT_REFLECTION_TEMPORAL_V025_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"

uniform_sampler2D(currentReflectionTex, 0);
uniform_sampler2D(prepassTex, 1);
uniform_sampler2D(prepassDepthTex, 2);
uniform_sampler2D(velocityTex, 3);
uniform_sampler2D(historyReflectionTex, 4);
uniform_sampler2D(materialSpecTex, 5);

cbuffer perDraw : register(b0)
{
    uniform float reflectionTemporalBlend;
    uniform float reflectionHistoryDepthTolerance;
    uniform float reflectionDenoiseStrength;
#ifdef BEAMRT_REFLECTION_TUNING
    uniform float reflectionFilterRadiusScale;
#endif
    uniform float reflectionHistoryValid;
    uniform float reflectionCameraMotion;
    uniform float reflectionMaxRoughness;
#ifdef BEAMRT_REFLECTION_COLOR_FILTER
    uniform float reflectionColorFilterEnabled;
#endif
#ifdef BEAMRT_REFLECTION_GGX_HISTORY
    uniform float reflectionSamplingMode;
#endif
#ifdef BEAMRT_REFLECTION_GGX_PLAYABLE_RECONSTRUCTION
    uniform float reflectionReconstructionMode;
    uniform float reflectionFrameDelta;
#endif
#ifdef BEAMRT_REFLECTION_HIT_AWARE
    uniform float reflectionHitAwareEnabled;
#endif
    uniform float2 oneOverTargetSize;
    uniform float2 targetSize;
    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#endif
