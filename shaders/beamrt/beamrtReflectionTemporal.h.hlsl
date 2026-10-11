#ifndef BEAMRT_REFLECTION_TEMPORAL_H_HLSL
#define BEAMRT_REFLECTION_TEMPORAL_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"

uniform_sampler2D(currentReflectionTex, 0);
uniform_sampler2D(prepassTex, 1);
uniform_sampler2D(prepassDepthTex, 2);
uniform_sampler2D(velocityTex, 3);
uniform_sampler2D(historyReflectionTex, 4);

cbuffer perDraw : register(b0)
{
    uniform float reflectionTemporalBlend;
    uniform float reflectionHistoryDepthTolerance;
    uniform float reflectionDenoiseStrength;
    uniform float reflectionHistoryValid;
    uniform float2 oneOverTargetSize;
    uniform float2 targetSize;
    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#endif
