// BeamRT independent screen-space directional sunlight shadow tracer v003.
// This pass does not modify BeamNG lighting. R = own sun visibility,
// G = view-path coverage/confidence, B = N.L, A = surface present.
// Incomplete view paths must NOT be interpreted as definitively sun-lit.
#include "shaders/common/postFx/postFx.h.hlsl"

uniform_sampler2D(prepassTex, 0);
uniform_sampler2D(prepassDepthTex, 1);

cbuffer perDraw : register(b0)
{
    uniform float3 eyePosWorld; // BeamNG auto-bound main camera world position.
    uniform float3 sunDirection; // BeamNG auto-bound: world direction toward sun.
    uniform float shadowRaySteps;
    uniform float shadowRayDistance; // world metres
    uniform float shadowNormalBias; // world metres
    uniform float shadowThickness; // world metres
    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

// Reuses the eye-ray basis used by BeamRT's GI and reflection tracers.
bool projectShadowPoint(
    float3 eyeVector, float3 currentEyeRay, float3 eyeRayDu,
    float3 eyeRayDv, float2 currentUv,
    out float2 projectedUv, out float projectedDepth)
{
    float3 normal = cross(eyeRayDu, eyeRayDv);
    float determinant = dot(currentEyeRay, normal);
    if (abs(determinant) < 0.00000001)
    {
        projectedUv = 0.0;
        projectedDepth = 0.0;
        return false;
    }
    projectedDepth = dot(eyeVector, normal) / determinant;
    float weightedDu = dot(currentEyeRay, cross(eyeVector, eyeRayDv)) / determinant;
    float weightedDv = dot(currentEyeRay, cross(eyeRayDu, eyeVector)) / determinant;
    projectedUv = currentUv + float2(weightedDu, weightedDv) /
                  max(projectedDepth, 0.00000001);
    return projectedDepth > 0.00000001;
}

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float4 center = decodeGBuffer(
        TEX_SAMPLER(prepassDepthTex), TEX_SAMPLER(prepassTex),
        IN.uv0, projParams);
    if (center.w >= 0.9999) return float4(1.0, 0.0, 0.0, 0.0);

    float3 sun = sunDirection;
    float sunLengthSq = dot(sun, sun);
    if (sunLengthSq < 0.000001)
        return float4(1.0, 0.0, 0.0, 1.0);
    sun *= rsqrt(sunLengthSq);

    float nDotL = saturate(dot(normalize(center.xyz), sun));
    if (nDotL < 0.0001)
    {
        // Back-facing receivers get zero DIRECT sun from N.L, but that is not
        // a cast-shadow ray hit. Preserve R=unoccluded and G=not traced;
        // otherwise every north-facing wall appears as a red "ray hit".
        return float4(1.0, 0.0, 0.0, 1.0);
    }

    float dx = ddx(IN.uv0.x);
    float dy = ddy(IN.uv0.y);
    if (abs(dx) < 0.00000001 || abs(dy) < 0.00000001)
        return float4(1.0, 0.0, nDotL, 1.0);

    float3 rayDu = ddx(IN.wsEyeRay) / dx;
    float3 rayDv = ddy(IN.wsEyeRay) / dy;
    float bias = max(shadowNormalBias, 0.005);
    float3 rayOrigin = eyePosWorld + IN.wsEyeRay * center.w +
                       center.xyz * bias;

    int stepCount = clamp((int)shadowRaySteps, 4, 96);
    float reach = max(shadowRayDistance, 0.5);
    float thickness = max(shadowThickness, 0.02);
    float2 farCorner = rtParams0.xy + rtParams0.zw;
    float2 viewportMin = min(rtParams0.xy, farCorner) + 0.0001;
    float2 viewportMax = max(rtParams0.xy, farCorner) - 0.0001;

    float lastDepthDelta = -10000.0;
    float acceptedSamples = 0.0;

    [loop]
    for (int index = 0; index < 96; ++index)
    {
        if (index >= stepCount) break;
        float fraction = ((float)index + 1.0) / (float)stepCount;
        // Quadratic spacing devotes steps to contacts while reaching distance.
        float travel = 0.03 + reach * fraction * fraction;
        float3 worldPoint = rayOrigin + sun * travel;
        float2 uv;
        float rayEyeDepth;
        bool projected = projectShadowPoint(
            worldPoint - eyePosWorld, IN.wsEyeRay, rayDu, rayDv,
            IN.uv0, uv, rayEyeDepth);

        if (!projected || rayEyeDepth >= 0.9999 ||
            rayEyeDepth <= max(projParams.x / max(projParams.y, 0.0001), 0.00000001) ||
            any(uv <= viewportMin) || any(uv >= viewportMax))
        {
            // A ray exiting the view is UNKNOWN, not guaranteed illuminated.
            return float4(1.0, acceptedSamples / (float)stepCount, nDotL, 1.0);
        }

        float ndc = tex2Dlod(prepassDepthTex, float4(uv, 0.0, 0.0)).r;
        float sceneDepth = realToEyeLinearDepth(
            ndcToRealDepth(ndc, projParams.zw), projParams);
        if (sceneDepth >= 0.9999) continue;

        acceptedSamples += 1.0;
        // Positive delta means the ray is behind camera-visible geometry.
        float deltaWorld = (rayEyeDepth - sceneDepth) * projParams.y;
        float tolerance = max(thickness, reach * fraction * 0.006);
        // Require transition from in front of a surface toward the rear.
        // This avoids treating unrelated foreground silhouettes as hits.
        if (lastDepthDelta < -0.008 &&
            deltaWorld >= 0.0 && deltaWorld <= tolerance)
        {
            return float4(0.0, 1.0, nDotL, 1.0);
        }
        lastDepthDelta = deltaWorld;
    }

    return float4(1.0, saturate(acceptedSamples / (float)stepCount), nDotL, 1.0);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
