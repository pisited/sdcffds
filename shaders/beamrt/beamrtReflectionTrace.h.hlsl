#ifndef BEAMRT_REFLECTION_TRACE_H_HLSL
#define BEAMRT_REFLECTION_TRACE_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"

uniform_sampler2D(prepassTex, 0);
uniform_sampler2D(prepassDepthTex, 1);
uniform_sampler2D(backBufferTex, 2);
#ifdef BEAMRT_REFLECTION_COLOR_FILTER
uniform_sampler2D(reflectionRadianceTex, 4);
#endif
#ifdef BEAMRT_REFLECTION_GGX
uniform_sampler2D(materialSpecTex, 3);
#endif

cbuffer perDraw : register(b0)
{
    uniform float3 eyePosWorld;
    uniform float reflectionStepSize;
    uniform float reflectionThickness;
    uniform float reflectionNormalBias;
    uniform float reflectionMaxSteps;
    uniform float reflectionMaxDistance;
    uniform float reflectionMaxRoughness;
#ifdef BEAMRT_REFLECTION_TUNING
    uniform float reflectionSampleCellPixels;
    uniform float reflectionNoiseSeed;
    uniform float reflectionSourceFootprintScale;
#endif
#ifdef BEAMRT_REFLECTION_CONVERGENCE
    uniform float reflectionConvergenceEnabled;
#endif
#ifdef BEAMRT_REFLECTION_COLOR_FILTER
    uniform float reflectionColorFilterEnabled;
    uniform float2 reflectionHalfSize;
#endif
#ifdef BEAMRT_REFLECTION_GGX
    // 0 retains the legacy mirror ray; 1 samples the GGX visible-normal lobe.
    uniform float reflectionSamplingMode;
    uniform float reflectionSampleIndex;
#endif
#ifdef BEAMRT_REFLECTION_HIT_AWARE
    uniform float reflectionHitAwareEnabled;
    uniform float reflectionStableSmoothEnabled;
#endif
#ifdef BEAMRT_REFLECTION_DIAGNOSTICS
    // 0 beauty, 1 receiver, 2 validity, 3 hit UV, 4 depth error,
    // 5 raw hit colour, 6 weighted contribution, 7 source UV,
    // 8 rejection reason, 9 world reflection direction.
    uniform float reflectionDebugMode;
#endif
    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#endif
