#include "shaders/common/postFx/postFx.h.hlsl"

uniform_sampler2D(historyGITex, 0);
uniform_sampler2D(historyMomentsTex, 1);
uniform_sampler2D(velocityTex, 2);
uniform_sampler2D(stbnNoiseTex, 3);
uniform_sampler2D(blueNoiseTex, 4);
uniform_sampler2D(surfelRadianceTex, 5);

cbuffer perDraw : register(b0)
{
    uniform float2 giImageSize;
    uniform float historyValid;
    uniform float2 targetSize;
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
    // Use the actual atlas output pixel, independent of source rtParams.
    int2 pixel = (int2)floor(IN.hpos.xy);
    int2 imageSize = max((int2)giImageSize, int2(1, 1));
    if (pixel.x < imageSize.x && pixel.y < imageSize.y)
    {
        if (historyValid <= 0.5) return 0.0;
        float4 moments = historyMomentsTexTex.Load(int3(pixel, 0));
        float4 history = historyGITexTex.Load(int3(pixel, 0));
        float depth = moments.b > 0.5 ? max(moments.a, 0.0) : 0.0;
        return float4(history.rgb, depth);
    }
    if (pixel.x < imageSize.x && pixel.y < 2 * imageSize.y)
    {
        int2 giPixel = pixel - int2(0, imageSize.y);
        uint velocityWidth, velocityHeight;
        velocityTexTex.GetDimensions(velocityWidth, velocityHeight);
        float2 viewportUv = (float2(giPixel) + 0.5) / float2(imageSize);
        float2 uv = viewportCoordToRenderTarget(viewportUv, rtParams2);
        int2 velocityPixel = clamp((int2)floor(uv * float2(velocityWidth, velocityHeight)),
            int2(0, 0), max(int2(velocityWidth, velocityHeight) - 1, int2(0, 0)));
        return float4(velocityTexTex.Load(int3(velocityPixel, 0)).xy, 0.0, 0.0);
    }
    int2 noisePixel = pixel - int2(0, 2 * imageSize.y);
    if (noisePixel.y >= 0 && noisePixel.y < 1024)
    {
        if (noisePixel.x < 1024)
            return stbnNoiseTexTex.Load(int3(noisePixel, 0));
        if (noisePixel.x < 1152 && noisePixel.y < 128)
            return blueNoiseTexTex.Load(int3(noisePixel - int2(1024, 0), 0));
        return 0.0;
    }
    int2 surfelPixel = pixel - int2(0, 2 * imageSize.y + 1024);
    if (surfelPixel.x < 32 && surfelPixel.y >= 0 && surfelPixel.y < 4)
        return surfelRadianceTexTex.Load(int3(surfelPixel, 0));
    return 0.0;
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
