// Uses the production helpers, not rewritten CPU equivalents.
#define main BrtcUnusedEngineMain
#include "shaders/beamrt/coherent/beamrt_coherent_pass3_p.hlsl"
#undef main

PFXVertToPix mainV(uint index : SV_VertexID)
{
    PFXVertToPix v = (PFXVertToPix)0;
    v.uv0 = float2((index << 1) & 2, index & 2);
    v.uv1 = v.uv2 = v.uv3 = v.uv0;
    v.hpos = float4(v.uv0 * float2(2, -2) + float2(-1, 1), 0, 1);
    v.wsEyeRay = float3(v.uv0.x * 2 - 1, 1, 1 - v.uv0.y * 2) * 10;
    return v;
}

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float4 signal = sourceTexTex.Load(int3(0, 0, 0));
    float4 packed = BrtcPackHistory(signal, 0.375, float3(0, 0, 1), 17, uIntensity, 0, 5, 0.25);
    BrtcHistory h = BrtcUnpackHistory(packed);
    int mode = (int)uDebugView;
    if (mode == 0) return h.signal;
    if (mode == 1) return float4(h.depth, h.age, h.hit, h.rough);
    if (mode == 2)
    {
        float cosine = saturate(uIntensity);
        float value = WaterAngleMask(float3(sqrt(saturate(1-cosine*cosine)), 0, -cosine), float3(0, 0, 1));
        return float4(value, value, value, 1);
    }
    if (mode == 3)
    {
        h.age = uTraceQuality;
        bool ok = BrtcHistoryCompatible(h, 0, float3(0, 0, 1), uWaterSSR, uRoughnessEnd,
            float3(0, 0, uIntensity), 0.01);
        return float4(ok ? 1 : 0, 0, 0, 1);
    }
    if (mode == 4)
    {
        BrtcPrevCamera cam = BrtcEmptyPreviousCamera();
        float2 uv = 0; float depth = 0;
        bool solved = BrtcSolvePreviousUV(cam, float3(0.4, 0.8, uIntensity), uv, depth);
        return float4(uv, depth, solved ? 1 : 0);
    }
    if (mode == 5) return float4(h.misses, h.water, h.normal.z, h.age);
    if (mode == 6) return float4(BrtcScaleReflectionTranslation(float2(0.3, 0.4), float2(0.8, 0.9)), 0, 1);
    if (mode == 7) return packed;
    if (mode == 8) return BrtcUnpackHistory(signal).signal;
    if (mode == 9) return float4(BrtcStochasticSequence(IN.hpos.xy, 0, 1), 0, 1);
    if (mode == 10) return float4(BrtcApplyAddedWaterTint(signal.rgb, uWaterSSR, uIntensity), signal.a);
    if (mode == 11)
    {
        BrtcCacheTextureSizes();
        SSRProjectionBasis basis; basis.centerUV=float2(.5,.5);basis.screenCenter=0;
        SSRHit hit=BrtcMarchOneRay(float3(0,2,0),normalize(float3(0,1,.3)),basis,projParams,
            float2(.5,.5),0,1,85,float3(0,0,1));
        return float4(hit.uv,hit.t,hit.found?1:0);
    }
    if (mode == 12) return float4((float)BrtcTraceIterationBudget(),0,0,1);
    if (mode == 13)
    {
        BrtcCacheTextureSizes(); BrtcCacheScreenMapping(IN.wsEyeRay,IN.uv0);
        float4 center=sourceTexTex.Load(BrtcTexelAt(IN.uv0,gSourceSize,gSourceMaxCoord));
        float4 value=BrtcReuseStochastic(IN.uv0,center,projParams,IN.uv0);
        return float4(value.rgb*value.a,value.a);
    }
    if (mode == 14)
    {
        BrtcCacheTextureSizes(); BrtcCacheScreenMapping(IN.wsEyeRay,IN.uv0);
        float4 center=sourceTexTex.Load(BrtcTexelAt(IN.uv0,gSourceSize,gSourceMaxCoord));
        float hit;
        float4 value=BrtcReuseStochastic(IN.uv0,center,projParams,IN.uv0,hit);
        return float4(hit,value.a,value.r*value.a,1);
    }
    if (mode == 15)
    {
        float4 value=sourceTexTex.Load(int3((int2)IN.hpos.xy,0));
        return float4(BrtcEmbedHitCode(value.rgb,value.a>0 ? uIntensity : 63.0),value.a);
    }
    if (mode == 16)
        return float4(BrtcCoverageClampRadius(0.025,uIntensity,9,uRoughnessEnd,uWaterSSR),
            BrtcRoughStabilityWeight(uRoughnessEnd,uWaterSSR),0,1);
    if (mode == 17)
    {
        BrtcCacheTextureSizes();
        float hit;
        float4 value=BrtcSampleRoughTrace(IN.uv0,hit);
        return float4(hit,value.a,value.r*value.a,1);
    }
    if (mode == 18)
        return BrtcPackHistory(signal,uThicknessTexels,float3(0,-1,0),uTraceQuality,
            uIntensity,uWaterSSR,uFresnelStrength,uRoughnessEnd);
    if (mode == 19)
    {
        BrtcHistory value=BrtcUnpackHistory(signal);
        return float4(value.age,value.misses,value.depth,value.hit);
    }
    if (mode == 20)
    {
        float4 value=sourceTexTex.Load(int3((int2)IN.hpos.xy,0));
        return float4(BrtcExtractHitCode(value.rgb),value.a,value.r*value.a,1);
    }
    if (mode == 21)
        return float4(BrtcStochasticSequence(float2(37,floor(IN.hpos.y)),
            floor(IN.hpos.x),uStochasticRayCount),0,1);
    if (mode == 22)
    {
        // Smooth sample-domain integral with known mean 1. Not an SSR image
        // benchmark: this measures variance of the production sample sequence.
        float estimate=0;
        [loop] for (int i=0;i<16;++i)
        {
            if (i>=(int)uStochasticRayCount) break;
            float2 xi=BrtcStochasticSequence(IN.hpos.xy,(float)i,uStochasticRayCount);
            estimate+=xi.x+xi.y;
        }
        return float4((estimate/max(uStochasticRayCount,1.0)).xxx,1);
    }
    if (mode == 23) return float4((float)BrtcStochasticRayBudget(),0,0,1);
    if (mode == 24) return float4(BrtcHistoryFreshWeight(uIntensity,uTemporalStrength).xxx,1);
    return 0;
}
