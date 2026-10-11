#ifndef BEAMRT_COPY_H_HLSL
#define BEAMRT_COPY_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"

uniform_sampler2D(inputTex, 0);

cbuffer perDraw : register(b0)
{
    PURE_POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#endif // BEAMRT_COPY_H_HLSL
