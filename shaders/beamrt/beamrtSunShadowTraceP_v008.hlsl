// BeamRT independent screen-space directional sunlight shadow tracer v008.
// Four runtime hit models, including a receiver-plane self-shadow guard.
// Screen-space results remain uncertain around off-screen/alpha/edge casters.
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
    uniform float shadowHitModel; // 0 legacy, 1 refined, 2 validated, 3 geometric
    uniform float shadowRefineSteps; // 0..6 binary refinement samples
    uniform float shadowTraceDiagnostic; // 1 = deliberately output model identifier for A/B validation
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
    // Bypass all ray tracing to verify *independent* pass constants and
    // preview textures. Visible grayscale values should be:
    // legacy=.125, refined=.375, validated=.625, geometric=.875.
    if (shadowTraceDiagnostic > 0.5)
        return float4((shadowHitModel + 0.5) * 0.25, 1.0, 1.0, 1.0);
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

    // A ray hit requires two consecutive depth samples that bracket an
    // actual front-to-back crossing. Do NOT treat the first positive sample
    // as a hit: it can be the receiver's own depth (self-shadow/acne).
    float lastDepthDelta = 0.0;
    bool hadPreviousValidSample = false;
    float previousTravel = 0.0;
    float acceptedSamples = 0.0;
    bool uncertainDiscontinuity = false;

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
        if (sceneDepth >= 0.9999)
        {
            // Missing depth cannot form a valid crossing pair. A later object
            // silhouette must start a new bracket instead of inheriting an
            // old front-facing sample from across empty sky.
            hadPreviousValidSample = false;
            continue;
        }

        acceptedSamples += 1.0;
        // Positive delta means the ray is behind camera-visible geometry.
        float deltaWorld = (rayEyeDepth - sceneDepth) * projParams.y;
        float tolerance = max(thickness, reach * fraction * 0.006);
        // Require transition from in front of a surface toward the rear.
        // This avoids treating unrelated foreground silhouettes as hits.
        // Keep the exact v004 acceptance rule available for runtime A/B.
        if (shadowHitModel < 0.5)
        {
            if (hadPreviousValidSample &&
                lastDepthDelta < -0.008 &&
                deltaWorld >= 0.0 && deltaWorld <= tolerance)
                return float4(0.0, 1.0, nDotL, 1.0);
        }
        else if (hadPreviousValidSample &&
                 lastDepthDelta < -0.008 &&
                 deltaWorld >= 0.0)
        {
            // The coarse sample may overshoot a thin occluder by far more
            // than the permitted thickness. Binary-search the travel segment
            // instead of silently missing it, but never accept a segment
            // that crosses a missing-depth pixel or the viewport boundary.
            float lowTravel = previousTravel;
            float highTravel = travel;
            bool bracketValid = true;
            int refinementCount = clamp((int)shadowRefineSteps, 0, 6);

            [loop]
            for (int refine = 0; refine < 6; ++refine)
            {
                if (refine >= refinementCount) break;
                float middleTravel = 0.5 * (lowTravel + highTravel);
                float2 middleUv;
                float middleEyeDepth;
                bool middleProjected = projectShadowPoint(
                    rayOrigin + sun * middleTravel - eyePosWorld,
                    IN.wsEyeRay, rayDu, rayDv, IN.uv0,
                    middleUv, middleEyeDepth);
                if (!middleProjected || middleEyeDepth >= 0.9999 ||
                    middleEyeDepth <= max(projParams.x / max(projParams.y, 0.0001), 0.00000001) ||
                    any(middleUv <= viewportMin) || any(middleUv >= viewportMax))
                {
                    bracketValid = false;
                    break;
                }
                float middleNdc = tex2Dlod(
                    prepassDepthTex, float4(middleUv, 0.0, 0.0)).r;
                float middleSceneDepth = realToEyeLinearDepth(
                    ndcToRealDepth(middleNdc, projParams.zw), projParams);
                if (middleSceneDepth >= 0.9999)
                {
                    bracketValid = false;
                    break;
                }
                float middleDelta = (middleEyeDepth - middleSceneDepth) *
                                    projParams.y;
                if (middleDelta >= 0.0)
                    highTravel = middleTravel;
                else
                    lowTravel = middleTravel;
            }

            // Recheck the *final* hit candidate rather than accepting an
            // arbitrary coarse sign crossing or depth-buffer discontinuity.
            if (bracketValid)
            {
                float2 hitUv;
                float hitEyeDepth;
                bool hitProjected = projectShadowPoint(
                    rayOrigin + sun * highTravel - eyePosWorld,
                    IN.wsEyeRay, rayDu, rayDv, IN.uv0, hitUv, hitEyeDepth);
                if (hitProjected && hitEyeDepth < 0.9999 &&
                    all(hitUv > viewportMin) && all(hitUv < viewportMax))
                {
                    float hitNdc = tex2Dlod(
                        prepassDepthTex, float4(hitUv, 0.0, 0.0)).r;
                    float hitSceneDepth = realToEyeLinearDepth(
                        ndcToRealDepth(hitNdc, projParams.zw), projParams);
                    float hitDelta = (hitEyeDepth - hitSceneDepth) *
                                     projParams.y;
                    // Avoid counting a nearly immediate receiver departure
                    // or a gross depth disagreement as a cast shadow.
                    float departure = highTravel;
                    float minDeparture = max(0.05, bias * 1.5);
                    if (hitSceneDepth < 0.9999 &&
                        departure > minDeparture &&
                        hitDelta >= -0.002 &&
                        hitDelta <= tolerance)
                    {
                        // Model 1 preserves v005 exactly. Model 2 checks
                        // depth coherence around the candidate caster.
                        if (shadowHitModel < 1.5)
                            return float4(0.0, 1.0, nDotL, 1.0);

                        // In the geometric mode, first check for a coplanar
                        // self-intersection. A depth crossing against the
                        // receiver's own sidewalk/road plane is not evidence
                        // of a separate shadow caster.
                        bool sameReceiverPlane = false;
                        if (shadowHitModel >= 2.5)
                        {
                            float4 hitSurface = decodeGBuffer(
                                TEX_SAMPLER(prepassDepthTex),
                                TEX_SAMPLER(prepassTex), hitUv, projParams);
                            if (hitSurface.w < 0.9999)
                            {
                                float3 receiverNormal = normalize(center.xyz);
                                float3 casterNormal = normalize(hitSurface.xyz);
                                float3 hitEyeRay = IN.wsEyeRay +
                                    rayDu * (hitUv.x - IN.uv0.x) +
                                    rayDv * (hitUv.y - IN.uv0.y);
                                // Eye-relative positions avoid large world
                                // coordinates and share the same reconstruction
                                // convention as the main shadow ray.
                                float3 casterOffset =
                                    hitEyeRay * hitSurface.w -
                                    IN.wsEyeRay * center.w;
                                float receiverPlaneDistance =
                                    abs(dot(casterOffset, receiverNormal));
                                sameReceiverPlane =
                                    dot(receiverNormal, casterNormal) > 0.965 &&
                                    receiverPlaneDistance < max(0.03, bias * 1.25);
                            }
                        }

                        // Keep v006's original half-pixel neighborhood intact
                        // when "validated" is selected. "geometric" uses a
                        // wider 1.5-pixel radius to reach distinct depth
                        // texels even with point sampling.
                        float2 offsetUv =
                            (shadowHitModel >= 2.5 ? 1.5 : 0.5) *
                            float2(abs(dx), abs(dy));
                        float2 sampleUv[4] = {
                            hitUv + float2(offsetUv.x, 0.0),
                            hitUv - float2(offsetUv.x, 0.0),
                            hitUv + float2(0.0, offsetUv.y),
                            hitUv - float2(0.0, offsetUv.y)
                        };
                        float agreeingNeighbors = 0.0;
                        float depthWindowWorld = max(thickness * 1.5, 0.15);
                        [unroll]
                        for (int neighbor = 0; neighbor < 4; ++neighbor)
                        {
                            if (any(sampleUv[neighbor] <= viewportMin) ||
                                any(sampleUv[neighbor] >= viewportMax))
                                continue;
                            float neighborNdc = tex2Dlod(
                                prepassDepthTex,
                                float4(sampleUv[neighbor], 0.0, 0.0)).r;
                            float neighborEyeDepth = realToEyeLinearDepth(
                                ndcToRealDepth(neighborNdc, projParams.zw),
                                projParams);
                            if (neighborEyeDepth < 0.9999 &&
                                abs(neighborEyeDepth - hitSceneDepth) *
                                    projParams.y <= depthWindowWorld)
                                agreeingNeighbors += 1.0;
                        }
                        if (!sameReceiverPlane && agreeingNeighbors >= 2.0)
                        {
                            // Nearby depths support a distinct caster.
                            return float4(0.0, 1.0, nDotL, 1.0);
                        }
                        if (!sameReceiverPlane && agreeingNeighbors >= 1.0)
                        {
                            // Thin potential caster: preserve a low-confidence
                            // magenta/purple candidate in classification.
                            return float4(0.0, 0.45, nDotL, 1.0);
                        }
                        // Rejected self-plane hits and unsupported silhouettes
                        // become UNKNOWN, not a confirmed shadow nor proof of
                        // sunlight. Continue searching for a real occluder.
                        uncertainDiscontinuity = true;
                    }
                }
            }
        }
        lastDepthDelta = deltaWorld;
        previousTravel = travel;
        hadPreviousValidSample = true;
    }

    float finalCoverage = saturate(acceptedSamples / (float)stepCount);
    if (shadowHitModel >= 1.5 && uncertainDiscontinuity)
        finalCoverage = min(finalCoverage, 0.25);
    return float4(1.0, finalCoverage, nDotL, 1.0);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
