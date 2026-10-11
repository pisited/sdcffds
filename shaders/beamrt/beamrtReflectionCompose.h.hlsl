#ifndef BEAMRT_REFLECTION_COMPOSE_H_HLSL
#define BEAMRT_REFLECTION_COMPOSE_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"

uniform_sampler2D(backBufferTex, 0);
uniform_sampler2D(temporalReflectionTex, 1);
uniform_sampler2D(prepassTex, 2);
#ifdef BEAMRT_MATERIAL_FRESNEL
uniform_sampler2D(materialSpecTex, 3);
#endif

cbuffer perDraw : register(b0)
{
    uniform float reflectionStrength;
    uniform float reflectionMaxRoughness;
#ifdef BEAMRT_REFLECTION_GGX
    uniform float reflectionSamplingMode;
#endif
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
    uniform float reflectionDebugMode;
#endif
    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#endif
