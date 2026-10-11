#ifndef BEAMRT_TEMPORAL_H_HLSL
#define BEAMRT_TEMPORAL_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"

uniform_sampler2D(currentGITex, 0);
uniform_sampler2D(prepassTex, 1);
uniform_sampler2D(prepassDepthTex, 2);
uniform_sampler2D(velocityTex, 3);
uniform_sampler2D(historyTex, 4);
#ifdef BEAMRT_SIX_INPUT_TEMPORAL
// PostEffect binds only six texture inputs. Keep the historical depth and
// support validation intact, using the preceding frame's moments for variance.
uniform_sampler2D(historyMomentsTex, 5);
#define momentsTexTex historyMomentsTexTex
#define momentsTex_sampler_ historyMomentsTex_sampler_
#else
#ifdef BEAMRT_VARIANCE_GUIDED
uniform_sampler2D(momentsTex, 5);
#endif
#ifdef BEAMRT_PRESERVE_HIT_CONFIDENCE
uniform_sampler2D(historyMomentsTex, 6);
#endif
#endif

cbuffer perDraw : register(b0)
{
    uniform float temporalBlend;
    uniform float historyDepthTolerance;
    uniform float denoiseStrength;
    uniform float historyValid;
    uniform float2 oneOverTargetSize;
    uniform float2 targetSize;
#ifdef BEAMRT_PROGRESSIVE_ACCUMULATION
    uniform float progressiveEnabled;
    uniform float progressiveCurrentWeight;
    uniform float progressiveClampStrength;
    uniform float progressiveSampleCount;
#ifdef BEAMRT_LOW_PATH_RESCUE
    uniform float progressivePathCount;
    uniform float lowPathRescue;
#endif
#endif
#ifdef BEAMRT_VARIANCE_GUIDED
    uniform float svgfStrength;
    uniform float svgfVarianceScale;
#endif
#ifdef BEAMRT_RAY_HIT_DIAGNOSTIC
    uniform float giTraceDebugMode;
#endif
#ifdef BEAMRT_ECHO_HISTORY_GUARD
    uniform float echoHistoryGuard;
#endif
#ifdef BEAMRT_CAMERA_MOTION_GUARD
    uniform float cameraMotion;
#endif
    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#endif // BEAMRT_TEMPORAL_H_HLSL
