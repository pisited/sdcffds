#ifndef BEAMRT_CLEAN_RADIANCE_V059_H_HLSL
#define BEAMRT_CLEAN_RADIANCE_V059_H_HLSL

#include "shaders/common/postFx/postFx.h.hlsl"

// Slots 0-3 receive their own BeamNG PostFX target-space transforms through
// processPostFxVert. Emissive uses the BaseColor cache UV because all accepted
// material caches are captured from the same synchronized RenderView geometry.
uniform_sampler2D(prepassDepthTex, 0);
uniform_sampler2D(baseColorCacheTex, 1);
uniform_sampler2D(metallicCacheTex, 2);
uniform_sampler2D(lightInfoTex, 3);
uniform_sampler2D(emissiveCacheTex, 4);

cbuffer perDraw : register(b0)
{
    uniform float outputMode;
    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#endif // BEAMRT_CLEAN_RADIANCE_V059_H_HLSL
