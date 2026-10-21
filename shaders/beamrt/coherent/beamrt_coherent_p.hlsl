#include "beamrt_coherent.h.hlsl"

static const float2 BEAMRT_COH_UV_CLAMP_LO = float2(0.00005, 0.00005);
static const float2 BEAMRT_COH_UV_CLAMP_HI = float2(0.99995, 0.99995);

#include "beamrt_coherent_surface.hlsl"

#include "beamrt_coherent_common.hlsl"
#include "beamrt_coherent_history.hlsl"
#include "beamrt_coherent_water.hlsl"
#include "beamrt_coherent_projection.hlsl"
#include "beamrt_coherent_environment.hlsl"
#include "beamrt_coherent_trace.hlsl"
#include "beamrt_coherent_temporal.hlsl"
#include "beamrt_coherent_pyramid.hlsl"
#include "beamrt_coherent_composite.hlsl"

float4 main(PFXVertToPix IN) : SV_TARGET0
{
    float2 uv = IN.uv0;
    float4 projectionParams = projParams;
#ifdef BEAMRT_COH_SSR_PASS
    const int passIndex = BEAMRT_COH_SSR_PASS;
#else
    int passIndex = (int)uPass;
#endif

    if (passIndex == 4)
        return tex2Dlod(sourceTex, float4(uv, 0.0, 0.0));

    if (passIndex == 5)
        return DownsampleSceneColor(uv);

    BrtcCacheTextureSizes();
    gNativeRayDU=ddx(IN.wsEyeRay)/max(abs(ddx(uv.x)),1e-8);
    gNativeRayDV=ddy(IN.wsEyeRay)/max(abs(ddy(uv.y)),1e-8);
    if(uHistoryInterleave>0.5 && (passIndex==18 || (uUnifiedTemporal>0.5 && passIndex==2)))
    {
        float2 nativeSize=passIndex==18?gSourceSize:gDepthSize;
        float2 historySize=passIndex==18?float2(ceil(nativeSize.x*0.5),nativeSize.y):gSourceSize;
        float2 actualUV=BrtcHistoryReceiverUV((int2)IN.hpos.xy,historySize,nativeSize);
        IN.wsEyeRay+=gNativeRayDU*(actualUV.x-uv.x)+gNativeRayDV*(actualUV.y-uv.y);
        uv=actualUV;IN.uv0=uv;
        if(any(uv>=1.0))return 0;
    }
    if (passIndex == 10)
        BrtcCacheScreenMapping(IN.wsEyeRay, uv);

    if (passIndex == 11)
        return BrtcWriteGeometry(uv);

    if (passIndex == 0)
    {
        float4 result = 0;
        if ((int)uDebugView == 35) result = BrtcDebugCellFootprint(uv);
        else result = TraceSSR(IN, uv, projectionParams);
        return result;
    }

    if (passIndex == 10)
    {
        int2 reusePixel = int2(IN.hpos.xy);
        if (reusePixel.x >= (int)gSourceSize.x)
            return BrtcWriteReuseGuide(int2(reusePixel.x - (int)gSourceSize.x, reusePixel.y));
        uv = (float2(reusePixel) + 0.5) / gSourceSize;
        float4 center = sourceTexTex.Load(BrtcTexelAt(uv, gSourceSize, gSourceMaxCoord));
        float centerHitCode = BrtcExtractHitCode(center.rgb);
        if (uAdaptiveResolution < 0.5)
        {
            float4 reused = BrtcReuseStochastic(uv, center, projectionParams, uv + uTraceJitterUV, centerHitCode);
            return float4(BrtcEmbedHitCode(reused.rgb, centerHitCode), reused.a);
        }
        float4 glossy = 0;
        if (center.a >= 0.0)
            glossy = BrtcReuseStochastic(uv, center, projectionParams, uv + uTraceJitterUV, centerHitCode);
        float2 guideUV = clamp(uv + uTraceJitterUV, BEAMRT_COH_UV_CLAMP_LO, BEAMRT_COH_UV_CLAMP_HI);
        float4 guideDepth = LoadCombinedDepthPoint(guideUV);
        float4 guidePrepass = prepassTexTex.Load(BrtcTexelAt(guideUV, gPrepassSize, gPrepassMaxCoord));
        float gloss = BrtcAdaptiveGloss(LoadRoughness(guidePrepass), DecodePrepassNormal(guidePrepass),
                                       guideDepth.b > 0.5);
        float4 merged;
        if (center.a >= 0.0 && gloss >= 1.0)
            merged = glossy;
        else
        {
            float roughHitCode;
            float4 rough = BrtcSampleRoughTrace(uv + uTraceJitterUV, roughHitCode);
            merged = (center.a < 0.0) ? rough : BrtcMixReflectionSignal(rough, glossy, gloss);
            if (center.a < 0.0 || centerHitCode >= 62.5 ||
                (roughHitCode < 62.5 && rough.a * (1.0-gloss) > glossy.a * gloss))
                centerHitCode = roughHitCode;
        }
        if (merged.a <= 1e-5) centerHitCode = BEAMRT_COH_HIT_DISTANCE_INFINITE;
        return float4(BrtcEmbedHitCode(merged.rgb, centerHitCode), merged.a);
    }

    if (passIndex == 2)
        return DenoiseSSR(IN, uv, projectionParams);

    if (passIndex == 6)
        return BuildCombinedDepth(IN, uv, projectionParams);

    if (passIndex == 7)
        return DownsampleHiZ(IN, false);

    if (passIndex == 15)
        return DownsampleHiZ(IN, true);

    if (passIndex == 8)
        return PackHiZLevels(IN);

    if (passIndex == 9)
        return BrtcWriteCameraHistory(IN, projectionParams);

    return CompositeSSR(IN, uv, projectionParams);
}
