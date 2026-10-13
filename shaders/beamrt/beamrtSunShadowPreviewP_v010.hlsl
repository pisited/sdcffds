// BeamRT independent sunlight shadow preview v010: persistent world-box caster diagnostic.
// Samples independent full-frame shadow outputs when model split is active.
// Existing preview views keep their prior numeric IDs; model-split uniforms are additional.
#include "shaders/common/postFx/postFx.h.hlsl"

uniform_sampler2D(shadowDataTex, 0);
uniform_sampler2D(backBufferTex, 1);
uniform_sampler2D(nativeSunTex, 2);
uniform_sampler2D(compareShadowDataTex, 3);

cbuffer perDraw : register(b0)
{
    uniform float shadowViewMode;
    uniform float splitEnabled;
    uniform float modelSplitEnabled;
    uniform float modelSplitViewMode; // 0 classification, 1 visibility, 2 coverage, 3 incidence, 4 difference
    uniform float splitPosition;  // normalized viewport horizontal coordinate
    uniform float splitLeftMode;
    uniform float splitRightMode;
    uniform float splitLineWidth; // physical pixels
    uniform float4 splitLineColor; // linear RGB + alpha
    uniform float3 sunDirection;
    uniform float hybridInvertNative; // 0 native R as visibility; 1 inverted
    uniform float hybridMinConfidence; // trace ray coverage required for detail
    uniform float hybridDetailStrength; // 0..1 optional detail, no native erasure
    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

// Debug-only hybrid: BeamNG native visibility is the base. BeamRT is
// permitted to add occlusion only when its ray hit and path confidence are
// usable. Unknown, off-screen and no-receiver pixels use native as fallback.
// IMPORTANT: not safe to multiply into BeamNG's already-shadowed backbuffer.
float3 beamrtHybridTerms(float4 trace, float nativeRaw)
{
    float nativeVisibility = hybridInvertNative > 0.5
        ? (1.0 - nativeRaw) : nativeRaw;
    float confidence = saturate((trace.g - hybridMinConfidence) /
                                  max(1.0 - hybridMinConfidence, 0.0001));
    // G is a coverage heuristic, NOT a guarantee of accurate intersections.
    // Require an accepted hit (R=0), a front-facing receiver, and near-full
    // coverage, so the fallback dominates unreliable screen-space regions.
    float eligible = confidence * trace.a *
                     step(0.0001, trace.b) *
                     (1.0 - saturate(trace.r));
    float detailAmount = saturate(hybridDetailStrength) * eligible;
    float hybridVis = nativeVisibility * (1.0 - detailAmount);
    return float3(saturate(hybridVis), saturate(detailAmount),
                  saturate(nativeVisibility));
}

float4 beamrtPreviewMode(float mode, float4 shadowData, float4 sceneEncoded,
                         float nativeSun)
{
    // Explicit off-screen geometry proof: shader diagnostic 3 returns 1
    // only where the world-space AABB ray test detects a supplied caster.
    // No camera-visible caster pixels are needed for this result.
    if (mode > 16.5 && mode < 17.5)
        return float4(hdrEncode(float3(0.05, 0.95, 0.95) *
                                 saturate(shadowData.r)), 1.0);

    // Hybrid scene preview preserves the already-shadowed native backbuffer.
    // Only add cautious screen-space detail while native sun reports lit.
    // Never multiply native visibility into the scene a second time.
    if (mode > 15.5 && mode < 16.5)
    {
        float3 blend = beamrtHybridTerms(shadowData, nativeSun);
        float additionalOcclusion = blend.g * blend.b;
        if (additionalOcclusion <= 0.0001)
            return sceneEncoded;
        float3 sceneLinear = max(hdrDecode(sceneEncoded.rgb), 0.0);
        return float4(hdrEncode(sceneLinear * (1.0 - additionalOcclusion)),
                      sceneEncoded.a);
    }

    // Modes 13-15 are confidence-aware hybrid previews. They do not modify
    // production lighting and MUST NOT run on hit-telemetry buffers.
    if (mode > 12.5 && mode < 15.5)
    {
        float3 blend = beamrtHybridTerms(shadowData, nativeSun);
        float3 diagnosticColor = mode < 13.5
            ? blend.r.xxx
            : (mode < 14.5
                ? blend.g.xxx
                : float3(blend.g, blend.b * (1.0 - blend.g), 0.0));
        return float4(hdrEncode(diagnosticColor), 1.0);
    }

    // Modes 10-12 consume tracer telemetry, NOT the standard visibility RGBA.
    // Black = no confirmed/candidate caster; dim purple = weak candidate.
    if (mode > 9.5 && mode < 12.5)
    {
        if (shadowData.a < 0.25)
            return float4(hdrEncode(float3(0.0, 0.0, 0.0)), 1.0);
        float metric = mode < 10.5 ? shadowData.r :
                       (mode < 11.5 ? shadowData.g : shadowData.b);
        // Travel: red near, cyan far. Residual: red high, green small.
        // Self-plane: red near the receiver's plane, green separated.
        float3 diagnosticColor = (mode < 10.5)
            ? float3(1.0 - metric, metric, 0.22)
            : (mode < 11.5)
                ? float3(metric, 1.0 - metric, 0.15)
                : float3(1.0 - metric, metric, 0.12);
        if (shadowData.a < 0.75)
            diagnosticColor = lerp(diagnosticColor,
                                   float3(0.75, 0.12, 0.8), 0.5);
        return float4(hdrEncode(diagnosticColor), 1.0);
    }

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
        float4 color;
        if (modelSplitEnabled > 0.5)
        {
            // Both masks were independently traced over the entire scene
            // with different hit models. The divider only chooses which
            // result to display, so it can slide without rerunning traces.
            float4 otherMask = tex2D(compareShadowDataTex, IN.uv0);
            if (modelSplitViewMode > 6.5)
            {
                // Model-split telemetry IDs 7..9 map to regular preview
                // hitdistance/deptherror/selfplane IDs 10..12.
                float4 selected = viewU < splitPosition
                    ? shadowData : otherMask;
                color = beamrtPreviewMode(modelSplitViewMode + 3.0,
                    selected, scene, nativeSun);
            }
            else if (modelSplitViewMode > 5.5)
            {
                // Model-ID probe: v008 tracer bypasses ray marching and writes
                // each independently bound shadowHitModel ID into its R
                // channel. Different model choices MUST make different shades
                // on opposite sides of the divider.
                float4 selected = viewU < splitPosition
                    ? shadowData : otherMask;
                color = float4(hdrEncode(selected.r.xxx), 1.0);
            }
            else if (modelSplitViewMode > 3.5)
            {
                // "difference" (mode 4) keeps the old confidence mask;
                // "rawdifference" (mode 5) shows the unweighted disagreement
                // so we can see whether a mostly black result is truly
                // identical or merely hidden by low trace confidence.
                // Red: left occludes but right does not; green: opposite.
                float3 rawDelta = float3(
                    max(otherMask.r - shadowData.r, 0.0),
                    max(shadowData.r - otherMask.r, 0.0), 0.0);
                float trust = min(shadowData.g, otherMask.g) *
                    shadowData.a * otherMask.a *
                    step(0.0001, min(shadowData.b, otherMask.b));
                float3 delta = (modelSplitViewMode > 4.5)
                    ? rawDelta : rawDelta * trust;
                color = float4(hdrEncode(delta), 1.0);
            }
            else
            {
                float4 selectedMask = viewU < splitPosition
                    ? shadowData : otherMask;
                color = beamrtPreviewMode(modelSplitViewMode,
                    selectedMask, scene, nativeSun);
            }
        }
        else
        {
            float selectedMode = viewU < splitPosition
                ? splitLeftMode : splitRightMode;
            color = beamrtPreviewMode(selectedMode,
                shadowData, scene, nativeSun);
        }
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
