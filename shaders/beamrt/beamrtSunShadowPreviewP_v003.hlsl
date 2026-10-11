// BeamRT independent sunlight shadow preview v003: selectable split-screen debugger.
// No extra tracing passes. Uses the same shadow / native / scene inputs as v002.
// Existing preview views keep their prior numeric IDs.
#include "shaders/common/postFx/postFx.h.hlsl"

uniform_sampler2D(shadowDataTex, 0);
uniform_sampler2D(backBufferTex, 1);
uniform_sampler2D(nativeSunTex, 2);

cbuffer perDraw : register(b0)
{
    uniform float shadowViewMode;
    uniform float splitEnabled;
    uniform float splitPosition;  // normalized viewport horizontal coordinate
    uniform float splitLeftMode;
    uniform float splitRightMode;
    uniform float splitLineWidth; // physical pixels
    uniform float4 splitLineColor; // linear RGB + alpha
    uniform float3 sunDirection;
    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float4 beamrtPreviewMode(float mode, float4 shadowData, float4 sceneEncoded,
                         float nativeSun)
{
    // Preserve original final image without an HDR decode/re-encode cycle.
    if (mode > 7.5 && mode < 8.5) return sceneEncoded;

    // Identity check works inside either split half as well.
    if (mode > 6.5 && mode < 7.5)
        return float4(hdrEncode(float3(10.0, 0.0, 10.0)), 1.0);

    float3 preview = 0.0;
    if (mode < 0.5)
    {
        // Red = occlusion, green = sampled clear ray, blue = incomplete ray.
        // Gray: back-facing surface. Never call N.L=0 a ray intersection.
        if (shadowData.a > 0.5 && shadowData.b <= 0.0001)
            preview = float3(0.10, 0.10, 0.10);
        else
            preview = float3(1.0 - shadowData.r,
                shadowData.r * shadowData.g, 1.0 - shadowData.g);
    }
    else if (mode < 1.5)
        preview = shadowData.r.xxx;
    else if (mode < 2.5)
        preview = shadowData.g.xxx;
    else if (mode < 3.5)
        preview = shadowData.b.xxx;
    else if (mode < 4.5)
        preview = nativeSun.xxx;
    else if (mode < 5.5)
    {
        // Diagnostic only. Mask polarity/encoding remains unverified.
        float confidence = shadowData.g * shadowData.a *
            step(0.0001, shadowData.b);
        preview = confidence * float3(
            max(nativeSun - shadowData.r, 0.0),
            max(shadowData.r - nativeSun, 0.0), 0.0);
    }
    else
    {
        float3 sun = sunDirection;
        sun = dot(sun, sun) > 0.000001
            ? normalize(sun) : float3(0.0, 0.0, 0.0);
        preview = sun * 0.5 + 0.5;
    }

    if (shadowData.a < 0.5 && mode < 4.5)
        preview = hdrDecode(sceneEncoded.rgb) * 0.05;
    return float4(hdrEncode(max(preview, 0.0)), 1.0);
}

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float4 shadowData = tex2D(shadowDataTex, IN.uv0);
    float4 scene = tex2D(backBufferTex, IN.uv0);
    float nativeSun = saturate(tex2D(nativeSunTex, IN.uv0).r);

    if (splitEnabled > 0.5)
    {
        // Use the viewport transform instead of assuming a full-target UV range.
        float viewU = (IN.uv0.x - rtParams0.x) /
                      max(abs(rtParams0.z), 0.000001);
        // Pixel-size derivative comes from the full-screen preview, not from
        // the (possibly half-resolution) shadow visibility target.
        float pixelUv = max(abs(ddx(viewU)), 0.00000001);
        float selectedMode = viewU < splitPosition
            ? splitLeftMode : splitRightMode;
        float4 color = beamrtPreviewMode(
            selectedMode, shadowData, scene, nativeSun);
        float halfWidth = 0.5 * max(splitLineWidth, 0.0) * pixelUv;
        if (abs(viewU - splitPosition) <= halfWidth)
        {
            float3 lineEncoded = hdrEncode(max(splitLineColor.rgb, 0.0));
            color.rgb = lerp(color.rgb, lineEncoded, saturate(splitLineColor.a));
        }
        return color;
    }

    return beamrtPreviewMode(shadowViewMode, shadowData, scene, nativeSun);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
