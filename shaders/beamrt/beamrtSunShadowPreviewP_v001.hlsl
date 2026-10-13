// BeamRT independent sun shadow preview v001. Debug only; never applies new
// shadows to the scene's final radiance. Textures: generated shadow, backbuffer,
// native BeamNG shadow mask. Kept separate to avoid disturbing GI.
#include "shaders/common/postFx/postFx.h.hlsl"

uniform_sampler2D(shadowDataTex, 0);
uniform_sampler2D(backBufferTex, 1);
uniform_sampler2D(nativeSunTex, 2);

cbuffer perDraw : register(b0)
{
    uniform float shadowViewMode;
    uniform float3 sunDirection;
    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float4 shadowData = tex2D(shadowDataTex, IN.uv0);
    float3 scene = hdrDecode(tex2D(backBufferTex, IN.uv0).rgb);
    float nativeSun = saturate(tex2D(nativeSunTex, IN.uv0).r);
    float3 preview;

    // 7: shader identity. This must be visibly magenta if preview executes.
    if (shadowViewMode > 6.5)
        return float4(hdrEncode(float3(10.0, 0.0, 10.0)), 1.0);

    if (shadowViewMode < 0.5) {
        // Red: our confirmed occlusion. Blue: unverified/off-screen path.
        float uncertainty = 1.0 - shadowData.g;
        preview = float3(1.0 - shadowData.r, shadowData.r * shadowData.g, uncertainty);
    }
    else if (shadowViewMode < 1.5) {
        preview = shadowData.r.xxx;
    }
    else if (shadowViewMode < 2.5) {
        preview = shadowData.g.xxx;
    }
    else if (shadowViewMode < 3.5) {
        preview = shadowData.b.xxx;
    }
    else if (shadowViewMode < 4.5) {
        preview = nativeSun.xxx;
    }
    else if (shadowViewMode < 5.5) {
        // R: native thinks lit, ours sees occluder.
        // G: ours thinks lit, native sees shadow. Uncertainty fades both.
        float confidence = shadowData.g * shadowData.a;
        preview = confidence * float3(
            max(nativeSun - shadowData.r, 0.0),
            max(shadowData.r - nativeSun, 0.0), 0.0);
    }
    else {
        float3 sun = sunDirection;
        sun = dot(sun,sun) > 0.000001 ? normalize(sun) : float3(0.0,0.0,0.0);
        preview = sun * 0.5 + 0.5;
    }
    // Do not display invalid sky pixels as shadows.
    if (shadowData.a < 0.5 && shadowViewMode < 4.5)
        preview = scene * 0.05;
    return float4(hdrEncode(max(preview, 0.0)), 1.0);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
