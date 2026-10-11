// BeamRT v0.102 Lighting Accuracy Experiment A (v079)
// Six texture inputs; isolated from the existing v078 shader and its includes.
#define BEAMRT_SIX_INPUT_COMPOSE 1
#define BEAMRT_RAY_HIT_DIAGNOSTIC 1
#define BEAMRT_CONFIDENCE_AWARE_COMPOSE 1
#define BEAMRT_CONSERVATIVE_RECEIVER_RESPONSE 1
#define BEAMRT_RECEIVER_REFLECTANCE 1
#define BEAMRT_PREMULTIPLIED_GI_COMPOSE 1
#define BEAMRT_LIGHTING_STAGE_DIAGNOSTICS 1
#define BEAMRT_RAW_DIAGNOSTIC_PRIMARY_INPUT 1
#define BEAMRT_RECEIVER_INPUT_DIAGNOSTICS 1

#include "beamrtLightingCompose_v079.h.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float beamrtContactOcclusion(PFXVertToPix IN, float4 centerDecoded)
{
    if (centerDecoded.w >= 0.9999 || contactShadowStrength <= 0.0)
    {
        return 0.0;
    }

    float uvDx = ddx(IN.uv1.x);
    float uvDy = ddy(IN.uv1.y);
    if (abs(uvDx) < 0.00000001 || abs(uvDy) < 0.00000001)
    {
        return 0.0;
    }

    float3 eyeRayDu = ddx(IN.wsEyeRay) / uvDx;
    float3 eyeRayDv = ddy(IN.wsEyeRay) / uvDy;
    float3 centerVector = IN.wsEyeRay * centerDecoded.w;
    float2 pixelDirections[8] = {
        float2( 1.0,  0.0), float2(-1.0,  0.0),
        float2( 0.0,  1.0), float2( 0.0, -1.0),
        float2( 0.7071,  0.7071), float2(-0.7071,  0.7071),
        float2( 0.7071, -0.7071), float2(-0.7071, -0.7071)
    };

    float occlusion = 0.0;
    [unroll]
    for (int sampleIndex = 0; sampleIndex < 8; ++sampleIndex)
    {
        float radiusPixels = sampleIndex < 4 ? 4.0 : 7.0;
        float2 deltaUv = pixelDirections[sampleIndex] * radiusPixels * oneOverTargetSize;
        float2 sampleUv = IN.uv1 + deltaUv;
        float4 neighborDecoded = decodeGBuffer(
            TEX_SAMPLER(prepassDepthTex),
            TEX_SAMPLER(prepassTex),
            sampleUv,
            projParams
        );
        if (neighborDecoded.w >= 0.9999)
        {
            continue;
        }

        float3 neighborEyeRay = IN.wsEyeRay + eyeRayDu * deltaUv.x + eyeRayDv * deltaUv.y;
        float3 separation = neighborEyeRay * neighborDecoded.w - centerVector;
        float distanceToSample = length(separation);
        if (distanceToSample <= 0.0001)
        {
            continue;
        }

        float horizon = saturate((dot(centerDecoded.xyz, separation / distanceToSample) - 0.04) * 3.0);
        float rangeWeight = saturate(1.0 - distanceToSample / 3.5);
        float normalCrease = lerp(0.65, 1.0, 1.0 - saturate(dot(centerDecoded.xyz, neighborDecoded.xyz)));
        occlusion += horizon * rangeWeight * normalCrease;
    }

    return saturate(occlusion * 0.22);
}

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float4 baseEncoded = tex2D(backBufferTex, IN.uv0);
#ifdef BEAMRT_LIGHTING_STAGE_DIAGNOSTICS
    // Diagnostic 12: deliberately unmistakable pixel-shader identity check.
    // If this is not visible, the v079 shader is not reaching the backbuffer.
    if (giLightingDiagnostic > 11.5)
    {
        return float4(hdrEncode(float3(10.0, 0.0, 10.0)), 1.0);
    }
#endif
#ifdef BEAMRT_LIGHTING_STAGE_DIAGNOSTICS
    if (giLightingDiagnostic > 0.5 && giLightingDiagnostic < 2.5)
    {
#ifdef BEAMRT_RAW_DIAGNOSTIC_PRIMARY_INPUT
        float3 stageGI = tex2D(temporalGITex, IN.uv1).rgb;
#else
        float3 stageGI = giLightingDiagnostic < 1.5
            ? tex2D(rawGITex, IN.uv1).rgb
            : tex2D(temporalGITex, IN.uv1).rgb;
#endif
        return float4(hdrEncode(max(stageGI, 0.0) * max(giLightingDiagnosticGain, 0.0)), baseEncoded.a);
    }
#endif
#ifdef BEAMRT_RAY_HIT_DIAGNOSTIC
    if (giTraceDebugMode > 0.5)
    {
        return float4(saturate(tex2D(temporalGITex, IN.uv1).rgb), 1.0);
    }
#endif
    if (giStrength <= 0.0)
    {
        return baseEncoded;
    }

    float3 baseLinear = hdrDecode(baseEncoded.rgb);
    float4 centerDecoded = decodeGBuffer(
        TEX_SAMPLER(prepassDepthTex),
        TEX_SAMPLER(prepassTex),
        IN.uv1,
        projParams
    );
    if (centerDecoded.w >= 0.9999)
    {
#ifdef BEAMRT_RECEIVER_INPUT_DIAGNOSTICS
        if (giLightingDiagnostic > 0.5)
        {
            return float4(hdrEncode(float3(0.0, 0.0, 0.0)), baseEncoded.a);
        }
#endif
        return baseEncoded;
    }
#ifdef BEAMRT_RECEIVER_INPUT_DIAGNOSTICS
    // Inspect each live input separately. These are surface-only displays;
    // ordinary sky pass-through would otherwise masquerade as captured GI.
#ifdef BEAMRT_SIX_INPUT_COMPOSE
    if (giLightingDiagnostic > 4.5 && giLightingDiagnostic < 8.5)
    {
        // Lua binds direct light, roughness, F0 or reflectance to input 1.
        // Input 5 remains the complete receiver response in every mode.
        float4 diagnosticInput = tex2D(temporalGITex, IN.uv1);
        float3 inputValue = 0.0;
        if (giLightingDiagnostic < 5.5)
        {
            inputValue = max(diagnosticInput.rgb, 0.0);
        }
        else if (giLightingDiagnostic < 6.5)
        {
            inputValue = saturate(diagnosticInput.b).xxx;
        }
        else if (giLightingDiagnostic < 7.5)
        {
            float3 specularF0 = saturate(diagnosticInput.rgb);
            float specularPeak = max(max(specularF0.r, specularF0.g), specularF0.b);
            inputValue = specularPeak.xxx * max(giLightingDiagnosticGain, 0.0);
        }
        else
        {
            inputValue = max(diagnosticInput.a, 0.0).xxx;
        }
        return float4(hdrEncode(inputValue), baseEncoded.a);
    }
#else
    if (giLightingDiagnostic > 4.5 && giLightingDiagnostic < 7.5)
    {
        float3 inputValue = 0.0;
        if (giLightingDiagnostic < 5.5)
        {
            inputValue = max(tex2D(receiverLightInfoTex, IN.uv2).rgb, 0.0);
        }
        else if (giLightingDiagnostic < 6.5)
        {
            inputValue = saturate(tex2D(prepassTex, IN.uv2).b).xxx;
        }
        else
        {
            float3 specularF0 = saturate(tex2D(receiverMaterialSpecTex, IN.uv2).rgb);
            float specularPeak = max(max(specularF0.r, specularF0.g), specularF0.b);
            inputValue = specularPeak.xxx * max(giLightingDiagnosticGain, 0.0);
        }
        return float4(hdrEncode(inputValue), baseEncoded.a);
    }
#endif
#endif

    // Full-resolution GI needs only the center/cardinal cross. Three-quarter
    // resolution adds diagonals, while half-resolution retains v0.050's full
    // 13-tap footprint and weights.
    float2 pixel = oneOverTargetSize;
    float2 offsets[13] = {
        float2(0.0, 0.0),
        float2(-pixel.x, 0.0), float2(pixel.x, 0.0),
        float2(0.0, -pixel.y), float2(0.0, pixel.y),
        float2(-pixel.x, -pixel.y), float2(pixel.x, -pixel.y),
        float2(-pixel.x,  pixel.y), float2(pixel.x,  pixel.y),
        float2(-3.0 * pixel.x, 0.0), float2(3.0 * pixel.x, 0.0),
        float2(0.0, -3.0 * pixel.y), float2(0.0, 3.0 * pixel.y)
    };
    int reconstructionTapCount = giRenderScale >= 0.875 ? 5 : (giRenderScale >= 0.625 ? 9 : 13);
    float3 giSum = 0.0;
    float weightSum = 0.0;
    float safeDepth = max(centerDecoded.w, 0.0001);
    [loop]
    for (int sampleIndex = 0; sampleIndex < 13; ++sampleIndex)
    {
        if (sampleIndex >= reconstructionTapCount)
        {
            break;
        }

        float2 sampleUv = IN.uv1 + offsets[sampleIndex];
        float4 sampleGI = tex2Dlod(temporalGITex, float4(sampleUv, 0.0, 0.0));
#ifdef BEAMRT_CONFIDENCE_AWARE_COMPOSE
        float sampleDepth = tex2Dlod(giMomentsTex, float4(sampleUv, 0.0, 0.0)).a;
        float relativeDepthDelta = abs(sampleDepth - centerDecoded.w) / safeDepth;
#else
        float relativeDepthDelta = abs(sampleGI.a - centerDecoded.w) / safeDepth;
#endif
        float depthWeight = 1.0 - smoothstep(0.002, 0.035, relativeDepthDelta);
        float3 sampleNormal = decodeNormalXY(tex2Dlod(prepassTex, float4(sampleUv, 0.0, 0.0)).xy);
        float normalWeight = pow(saturate(dot(centerDecoded.xyz, sampleNormal)), 12.0);
        float spatialWeight = sampleIndex == 0 ? 4.0 : (sampleIndex < 5 ? 2.0 : (sampleIndex < 9 ? 1.25 : 0.6));
#ifdef BEAMRT_CONFIDENCE_AWARE_COMPOSE
        // Normalize by compatible geometric coverage, not merely by the few
        // supported samples. A lone bright wheel/silhouette hit therefore stays
        // local instead of becoming full-strength across the whole footprint.
        float geometryWeight = depthWeight * normalWeight * spatialWeight;
        float supportWeight = smoothstep(0.02, 0.50, saturate(sampleGI.a));
#ifdef BEAMRT_PREMULTIPLIED_GI_COMPOSE
        // The tracer stores expected radiance with confidence already
        // premultiplied. Multiplying by support again squares confidence and
        // turns finite-reach transitions into visible dark borders.
        giSum += max(sampleGI.rgb, 0.0) * geometryWeight;
#else
        giSum += max(sampleGI.rgb, 0.0) * geometryWeight * supportWeight;
#endif
        weightSum += geometryWeight;
#else
        float weight = depthWeight * normalWeight * spatialWeight;
        giSum += max(sampleGI.rgb, 0.0) * weight;
        weightSum += weight;
#endif
    }
    float3 accumulatedGI = weightSum > 0.0001 ? giSum / weightSum : 0.0;

    // The v0.050 lighting design is intentionally unchanged below this point.
    const float3 luminanceWeights = float3(0.2126, 0.7152, 0.0722);
    float baseLuminance = dot(baseLinear, luminanceWeights);
    float giLuminance = dot(accumulatedGI, luminanceWeights);
    accumulatedGI = max(giLuminance.xxx + (accumulatedGI - giLuminance.xxx) * max(bounceSaturation, 0.0), 0.0);
    giLuminance = dot(accumulatedGI, luminanceWeights);

    float contrastPivot = 0.18;
    float shapedLuminance = contrastPivot * pow(
        max(giLuminance, 0.00001) / contrastPivot,
        max(giContrast, 0.01)
    );
    accumulatedGI *= shapedLuminance / max(giLuminance, 0.00001);

    // Legacy mode uses *display luminance* as a shadow proxy. This mistakes
    // intrinsically dark materials for shadows. Keep it strictly for A/B testing.
    float shadowMaskLegacy = 1.0 - smoothstep(0.20, 2.5, baseLuminance);
    float legacyShadowResponse = lerp(1.0, lerp(0.20, 1.0, shadowMaskLegacy), saturate(giShadowFocus));
    // New mode: a conservative, material-independent GI factor. Fine-scale
    // geometry occlusion is incorporated only once it has been computed below.
    // This is NOT directional sun/sky visibility; it cannot repair missing
    // off-screen blockers without a native shadow or scene-geometry input.
    float modelMix = saturate(lightingAccuracyMode);
    float shadowResponse = lerp(legacyShadowResponse,
                                lerp(1.0, 0.80, saturate(giShadowFocus)), modelMix);
#ifdef BEAMRT_SIX_INPUT_COMPOSE
    // RGB already contains the F0 and roughness gates from the preparation pass.
    float3 receiverResponse = max(tex2D(receiverResponseTex, IN.uv2).rgb, 0.0);
#elif defined(BEAMRT_RECEIVER_REFLECTANCE)
    // BeamNG does not retain diffuse albedo in a persistent PostFX target.
    // Estimate bounded receiver reflectance from outgoing scene radiance divided
    // by the engine's direct-light buffer. In weakly lit areas, fall back to a
    // compressed luminance proxy instead of allowing an unstable division.
    float3 receiverDirectLighting = max(tex2D(receiverLightInfoTex, IN.uv1).rgb, 0.0);
    float receiverDirectLuminance = dot(receiverDirectLighting, luminanceWeights);
    float receiverDisplayReflectance = saturate(baseLuminance / (baseLuminance + 0.25));
    float receiverDirectReflectance = saturate(
        baseLuminance / max(receiverDirectLuminance + 0.05, 0.05));
    float directEstimateConfidence = smoothstep(0.05, 0.50, receiverDirectLuminance);
    float approximateReflectance = lerp(
        receiverDisplayReflectance, receiverDirectReflectance, directEstimateConfidence);

    float receiverPeak = max(max(baseLinear.r, baseLinear.g), baseLinear.b);
    float3 receiverChroma = receiverPeak > 0.0001
        ? saturate(baseLinear / receiverPeak)
        : float3(1.0, 1.0, 1.0);
    float chromaConfidence = saturate(receiverPeak * 4.0);
    float3 receiverResponse = lerp(
        approximateReflectance.xxx,
        receiverChroma * approximateReflectance,
        saturate(giReceiverTint) * chromaConfidence);
#ifdef BEAMRT_RECEIVER_INPUT_DIAGNOSTICS
    if (giLightingDiagnostic > 7.5)
    {
        return float4(hdrEncode(max(receiverResponse, 0.0)), baseEncoded.a);
    }
#endif

    // RT1 stores specular/F0, not diffuse color. Values materially above the
    // dielectric F0 neighborhood identify metal-like receivers, whose diffuse
    // lobe must collapse instead of accepting the same GI as paint or rubber.
    float3 receiverSpecularF0 = saturate(tex2D(receiverMaterialSpecTex, IN.uv1).rgb);
    float receiverSpecularPeak = max(
        max(receiverSpecularF0.r, receiverSpecularF0.g), receiverSpecularF0.b);
    float metallicLikelihood = smoothstep(0.08, 0.24, receiverSpecularPeak);
    receiverResponse = max(
        receiverResponse * (1.0 - metallicLikelihood),
        float3(0.01, 0.01, 0.01));
#else
    float3 receiverChroma = clamp(baseLinear / max(baseLuminance, 0.05), 0.35, 2.5);
    float3 receiverResponse = lerp(float3(1.0, 1.0, 1.0), receiverChroma, saturate(giReceiverTint));
#endif
    float3 indirect = accumulatedGI
        * giStrength
        * exp2(clamp(giExposure, -8.0, 8.0))
        * shadowResponse
        * receiverResponse;
#if defined(BEAMRT_CONSERVATIVE_RECEIVER_RESPONSE) && !defined(BEAMRT_SIX_INPUT_COMPOSE)
    // The reflectance estimate handles dark and metallic materials; this remains
    // a separate roughness gate for polished dielectric receivers.
    float receiverRoughness = saturate(tex2D(prepassTex, IN.uv1).b);
    float diffuseReceiverWeight = lerp(0.18, 1.0, pow(receiverRoughness, 0.75));
    indirect *= diffuseReceiverWeight;
#endif

    float indirectLuminance = dot(indirect, luminanceWeights);
    float energyCeiling = max(0.001, max(giEnergyLimit, 0.0) * (0.35 + baseLuminance * 0.85));
    float hardScale = min(1.0, energyCeiling / max(indirectLuminance, 0.0001));
    float softLuminance = energyCeiling * (1.0 - exp(-indirectLuminance / energyCeiling));
    float softScale = softLuminance / max(indirectLuminance, 0.0001);
    indirect *= lerp(hardScale, softScale, saturate(giHighlightRolloff));
#ifdef BEAMRT_LIGHTING_STAGE_DIAGNOSTICS
    if (giLightingDiagnostic > 3.5 && giLightingDiagnostic < 4.5)
    {
        float3 materialResponse = receiverResponse;
#if defined(BEAMRT_CONSERVATIVE_RECEIVER_RESPONSE) && !defined(BEAMRT_SIX_INPUT_COMPOSE)
        materialResponse *= diffuseReceiverWeight;
#endif
        return float4(hdrEncode(max(materialResponse, 0.0)), baseEncoded.a);
    }
    if (giLightingDiagnostic > 2.5 && giLightingDiagnostic < 3.5)
    {
        // Exact visible indirect term, including every receiver/energy control.
        return float4(hdrEncode(max(indirect, 0.0) * max(giLightingDiagnosticGain, 0.0)), baseEncoded.a);
    }
#endif

    float contactOcclusion = beamrtContactOcclusion(IN, centerDecoded);
    // Original v078 applies contact darkening to every light component in the
    // already-lit native beauty buffer. Preserve it as the A/B baseline.
    float legacyContactResponse = lerp(1.0, 0.35, saturate(baseLuminance / 3.0));
    float legacyVisibility = 1.0 - contactOcclusion * saturate(contactShadowStrength) * legacyContactResponse;

    // Conservative mode: retain native lighting/shadows almost entirely.
    // The screen-space AO estimate cannot distinguish specular/emissive from
    // direct diffuse lighting, so its effect on the beauty buffer is capped.
    float conservativeVisibility = 1.0 - contactOcclusion * saturate(contactShadowStrength) * 0.25;
    float visibility = lerp(legacyVisibility, conservativeVisibility, modelMix);

    // Reduce duplicate energy and attenuate indirect light at local creases.
    // This is a safe-ish compensation, NOT genuine sky occlusion nor a
    // decomposition of BeamNG's already-lit radiance.
    float conservativeIndirectFactor = 0.85 * (1.0 - 0.45 * contactOcclusion);
    indirect *= lerp(1.0, conservativeIndirectFactor, modelMix);

#ifdef BEAMRT_LIGHTING_STAGE_DIAGNOSTICS
    // These diagnostic views do not require additional PostFX textures.
    if (giLightingDiagnostic > 8.5 && giLightingDiagnostic < 9.5)
    {
        return float4(hdrEncode(contactOcclusion.xxx), 1.0);
    }
    if (giLightingDiagnostic > 9.5 && giLightingDiagnostic < 10.5)
    {
        return float4(hdrEncode(visibility.xxx), 1.0);
    }
    if (giLightingDiagnostic > 10.5 && giLightingDiagnostic < 11.5)
    {
        return float4(hdrEncode(conservativeIndirectFactor.xxx), 1.0);
    }
#endif
    return float4(hdrEncode(baseLinear * visibility + indirect), baseEncoded.a);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
