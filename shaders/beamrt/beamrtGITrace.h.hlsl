#ifndef BEAMRT_GI_TRACE_H_HLSL
#define BEAMRT_GI_TRACE_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"

uniform_sampler2D(prepassTex, 0);
uniform_sampler2D(prepassDepthTex, 1);
uniform_sampler2D(backBufferTex, 2);
uniform_sampler2D(surfelRadianceTex, 3);

cbuffer perDraw : register(b0)
{
    uniform float3 eyePosWorld;
    uniform float rayStepSize;
    uniform float rayThickness;
    uniform float rayNormalBias;
    uniform float rayMaxSteps;
    uniform float giClamp;
    uniform float giFrameIndex;
    uniform float giCellSize;
    uniform float giPathCount;
    uniform float giSourceMode;
    uniform float worldGIStrength;
    uniform float worldLeakSuppression;
    uniform float surfelVisibilityTolerance;
    uniform float surfelCount;
    uniform float surfelMaxDistance;
    uniform float surfelCacheBlend;
    uniform float surfelCacheReset;
    uniform float4 surfelPositionRadius0;
    uniform float4 surfelNormalSource0;
    uniform float4 surfelPositionRadius1;
    uniform float4 surfelNormalSource1;
    uniform float4 surfelPositionRadius2;
    uniform float4 surfelNormalSource2;
    uniform float4 surfelPositionRadius3;
    uniform float4 surfelNormalSource3;
    uniform float4 surfelPositionRadius4;
    uniform float4 surfelNormalSource4;
    uniform float4 surfelPositionRadius5;
    uniform float4 surfelNormalSource5;
    uniform float4 surfelPositionRadius6;
    uniform float4 surfelNormalSource6;
    uniform float4 surfelPositionRadius7;
    uniform float4 surfelNormalSource7;
    uniform float4 surfelPositionRadius8;
    uniform float4 surfelNormalSource8;
    uniform float4 surfelPositionRadius9;
    uniform float4 surfelNormalSource9;
    uniform float4 surfelPositionRadius10;
    uniform float4 surfelNormalSource10;
    uniform float4 surfelPositionRadius11;
    uniform float4 surfelNormalSource11;
    uniform float4 surfelPositionRadius12;
    uniform float4 surfelNormalSource12;
    uniform float4 surfelPositionRadius13;
    uniform float4 surfelNormalSource13;
    uniform float4 surfelPositionRadius14;
    uniform float4 surfelNormalSource14;
    uniform float4 surfelPositionRadius15;
    uniform float4 surfelNormalSource15;
    uniform float4 surfelPositionRadius16;
    uniform float4 surfelNormalSource16;
    uniform float4 surfelPositionRadius17;
    uniform float4 surfelNormalSource17;
    uniform float4 surfelPositionRadius18;
    uniform float4 surfelNormalSource18;
    uniform float4 surfelPositionRadius19;
    uniform float4 surfelNormalSource19;
    uniform float4 surfelPositionRadius20;
    uniform float4 surfelNormalSource20;
    uniform float4 surfelPositionRadius21;
    uniform float4 surfelNormalSource21;
    uniform float4 surfelPositionRadius22;
    uniform float4 surfelNormalSource22;
    uniform float4 surfelPositionRadius23;
    uniform float4 surfelNormalSource23;
    uniform float4 surfelPositionRadius24;
    uniform float4 surfelNormalSource24;
    uniform float4 surfelPositionRadius25;
    uniform float4 surfelNormalSource25;
    uniform float4 surfelPositionRadius26;
    uniform float4 surfelNormalSource26;
    uniform float4 surfelPositionRadius27;
    uniform float4 surfelNormalSource27;
    uniform float4 surfelPositionRadius28;
    uniform float4 surfelNormalSource28;
    uniform float4 surfelPositionRadius29;
    uniform float4 surfelNormalSource29;
    uniform float4 surfelPositionRadius30;
    uniform float4 surfelNormalSource30;
    uniform float4 surfelPositionRadius31;
    uniform float4 surfelNormalSource31;
    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#endif // BEAMRT_GI_TRACE_H_HLSL
