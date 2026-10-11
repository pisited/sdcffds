#ifndef BEAMRT_COMPOSE_H_HLSL
#define BEAMRT_COMPOSE_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"

uniform_sampler2D(backBufferTex, 0);
uniform_sampler2D(temporalGITex, 1);

cbuffer perDraw : register(b0)
{
    uniform float giStrength;
    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#endif // BEAMRT_COMPOSE_H_HLSL
