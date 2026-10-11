#include "shaders/common/postFx/postFx.h.hlsl"

uniform_sampler2D(inputGITex, 0);
uniform_sampler2D(prepassTex, 1);
uniform_sampler2D(prepassDepthTex, 2);
uniform_sampler2D(momentsTex, 3);

cbuffer perDraw : register(b0)
{
    uniform float atrousStep;
    uniform float atrousStrength;
    uniform float atrousVarianceScale;
    uniform float giTraceDebugMode;
    uniform float2 targetSize;
    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float beamrtAtrousLuminance(float3 color)
{
    return dot(max(color, 0.0), float3(0.2126, 0.7152, 0.0722));
}

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float4 centerGI = tex2D(inputGITex, IN.uv0);
    if (atrousStrength <= 0.0001 || giTraceDebugMode > 0.5)
    {
        return centerGI;
    }

    float4 centerSurface = decodeGBuffer(
        TEX_SAMPLER(prepassDepthTex),
        TEX_SAMPLER(prepassTex),
        IN.uv1,
        projParams
    );
    if (centerSurface.w >= 0.9999)
    {
        return centerGI;
    }

    float4 centerMoments = tex2D(momentsTex, IN.uv0);
    float centerLuminance = beamrtAtrousLuminance(centerGI.rgb);
    float variance = max(centerMoments.g - centerMoments.r * centerMoments.r, 0.0);
    float historyConfidence = saturate((centerMoments.b - 1.0) / 7.0);
    float luminanceSigma = max(
        0.018,
        sqrt(variance + 0.000004) * max(atrousVarianceScale, 0.25)
    );
    // Freshly disoccluded pixels have unreliable variance. Keep their filter
    // radius conservative until the moments history has had time to settle.
    luminanceSigma *= lerp(0.55, 1.0, historyConfidence);

    float2 texelSize = 1.0 / max(targetSize, float2(1.0, 1.0));
    float safeStep = max(atrousStep, 1.0);
    float centerDepth = max(centerSurface.w, 0.0001);
    float3 colorSum = centerGI.rgb * 4.0;
    float supportSum = saturate(centerGI.a) * 4.0;
    float weightSum = 4.0;

    [unroll]
    for (int y = -1; y <= 1; ++y)
    {
        [unroll]
        for (int x = -1; x <= 1; ++x)
        {
            if (x == 0 && y == 0)
            {
                continue;
            }

            float2 sampleUv = IN.uv0 + float2((float)x, (float)y) * texelSize * safeStep;
            if (any(sampleUv < 0.0) || any(sampleUv > 1.0))
            {
                continue;
            }

            float4 sampleSurface = decodeGBuffer(
                TEX_SAMPLER(prepassDepthTex),
                TEX_SAMPLER(prepassTex),
                sampleUv,
                projParams
            );
            if (sampleSurface.w >= 0.9999)
            {
                continue;
            }

            float4 sampleGI = tex2Dlod(inputGITex, float4(sampleUv, 0.0, 0.0));
            float relativeDepth = abs(sampleSurface.w - centerSurface.w) / centerDepth;
            float depthWeight = exp2(-relativeDepth * (180.0 / safeStep));
            float normalAgreement = saturate(dot(centerSurface.xyz, sampleSurface.xyz));
            float normalWeight = pow(normalAgreement, max(10.0, 28.0 / sqrt(safeStep)));
            float luminanceDelta = abs(beamrtAtrousLuminance(sampleGI.rgb) - centerLuminance);
            float luminanceWeight = exp2(-luminanceDelta / luminanceSigma);
            float confidenceWeight = lerp(0.30, 1.0, saturate(sampleGI.a));
            float kernelWeight = (x == 0 || y == 0) ? 2.0 : 1.0;
            float weight = kernelWeight * depthWeight * normalWeight
                * luminanceWeight * confidenceWeight;

            colorSum += sampleGI.rgb * weight;
            supportSum += saturate(sampleGI.a) * weight;
            weightSum += weight;
        }
    }

    float3 filteredColor = colorSum / max(weightSum, 0.0001);
    float filteredSupport = supportSum / max(weightSum, 0.0001);
    // Do not manufacture a fully confident hit from neighboring samples. The
    // slight support lift fills sparse one-path holes while retaining the
    // tracer's confidence signal for the compose pass.
    filteredSupport = max(saturate(centerGI.a), filteredSupport * 0.88);
    float filterAmount = saturate(atrousStrength);
    return float4(
        max(lerp(centerGI.rgb, filteredColor, filterAmount), 0.0),
        saturate(lerp(centerGI.a, filteredSupport, filterAmount))
    );
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
