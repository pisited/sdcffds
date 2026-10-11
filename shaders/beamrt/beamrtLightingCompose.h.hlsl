#ifndef BEAMRT_COMPOSE_H_HLSL
#define BEAMRT_COMPOSE_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"

uniform_sampler2D(backBufferTex, 0);
uniform_sampler2D(temporalGITex, 1);
uniform_sampler2D(prepassTex, 2);
uniform_sampler2D(prepassDepthTex, 3);

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
    uniform float2 oneOverTargetSize;
    uniform float2 targetSize;
    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#endif // BEAMRT_COMPOSE_H_HLSL
