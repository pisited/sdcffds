#ifndef BEAMRT_BUFFER_DIAGNOSTIC_V001_H_HLSL
#define BEAMRT_BUFFER_DIAGNOSTIC_V001_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"

uniform_sampler2D(inputTex, 0);

cbuffer perDraw : register(b0)
{
    uniform float diagnosticChannel;
    uniform float diagnosticGain;
    uniform float diagnosticExposure;
    uniform float diagnosticHDRDecode;
    PURE_POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#endif // BEAMRT_BUFFER_DIAGNOSTIC_V001_H_HLSL
