#ifndef BEAMRT_COH_SSR_HISTORY_HLSL
#define BEAMRT_COH_SSR_HISTORY_HLSL
struct BrtcHistory
{
    float4 signal;
    float depth;
    float3 normal;
    float age;
    float hit;
    float water;
    float misses;
    float rough;
};
static float3 gNativeRayDU=float3(0,0,0),gNativeRayDV=float3(0,0,0);
float2 BrtcHistoryReceiverUV(int2 q,float2 size,float2 nativeSize)
{
    if(uHistoryInterleave>0.5)
        return float2((float(q.x*2+(q.y&1))+0.5)/nativeSize.x,(float(q.y)+0.5)/nativeSize.y);
    return (float2(q)+0.5)/size;
}
void BrtcHistoryGatherTap(float2 uv,float2 size,float2 nativeSize,int i,out int2 q,out float weight)
{
    float y=uv.y*size.y-0.5;int row=(int)floor(y)+(i>>1);
    float x=uv.x*size.x-0.5;
    if(uHistoryInterleave>0.5)x=(uv.x*nativeSize.x-0.5-float(row&1))*0.5;
    q=int2((int)floor(x)+(i&1),row);
    weight=((i&1)?frac(x):1.0-frac(x))*((i>>1)?frac(y):1.0-frac(y));
}
int3 BrtcHistoryNearestTexel(float2 uv,float2 size,float2 nativeSize)
{
    if(uHistoryInterleave<0.5)return BrtcTexelAt(uv,size,size-1.0);
    int row=clamp((int)floor(uv.y*nativeSize.y),0,(int)size.y-1);
    int col=(int)round((uv.x*nativeSize.x-0.5-float(row&1))*0.5);
    return int3(clamp(col,0,(int)size.x-1),row,0);
}
float BrtcHistoryEncodeDistance(float metres)
{
    return metres>0.0 && metres<1e5 ? clamp(round(log2(max(metres,0.05)/0.05)/0.019883),0.0,1022.0) : 1023.0;
}
float BrtcHistoryDecodeDistance(float code)
{
    return code>=1022.5 ? 1e6 : 0.05*exp2(code*0.019883);
}

float2 BrtcHistoryOct(float3 n)
{
    n /= max(dot(abs(n), 1.0), 1e-6);
    float2 p = n.xy;
    if (n.z < 0.0) p = (1.0 - abs(p.yx)) * float2(p.x >= 0 ? 1 : -1, p.y >= 0 ? 1 : -1);
    return p;
}
float3 BrtcHistoryUnoct(float2 p)
{
    float3 n = float3(p, 1.0 - abs(p.x) - abs(p.y));
    float t = saturate(-n.z);
    n.xy += float2(n.x >= 0 ? -t : t, n.y >= 0 ? -t : t);
    return normalize(n);
}
float4 BrtcPackHistory(float4 signal, float depth, float3 normal, float age,
                      float hit, float water, float misses, float rough)
{
    uint3 rgb = f32tof16(clamp(signal.rgb, 0.0, 65504.0)) & 0xFFFCu;
    uint m = (uint)clamp(round(misses), 0.0, 7.0);
    uint r = (uint)round(sqrt(saturate(rough)) * 7.0);
    rgb |= uint3(m & 3u, ((m >> 2) & 1u) | ((r & 1u) << 1), r >> 1);
    uint2 oct = (uint2)(clamp(round(BrtcHistoryOct(normal)*15.0),-15.0,15.0)+15.0);
    uint d = f32tof16(saturate(depth));
    uint a = (uint)round(saturate(signal.a) * 1023.0);
    uint n = (uint)clamp(round(age), 0.0, 31.0);
    uint h = (uint)clamp(round(hit), 0.0, 1023.0);
    float4 value=float4(rgb.x | ((rgb.y & 255u) << 16), (rgb.y >> 8) | (rgb.z << 8),
                  d | (oct.x << 16) | ((oct.y & 7u) << 21),
                  (oct.y >> 3) | (a << 2) | (n << 12) | ((h&63u) << 17) | ((water > 0.5 ? 1u : 0u) << 23))+1.0;
    return value*float4((h&64u)?-1:1,(h&128u)?-1:1,(h&256u)?-1:1,(h&512u)?-1:1);
}
BrtcHistory BrtcUnpackHistory(float4 value)
{
    uint4 sign=asuint(value)>>31;
    uint4 v = (uint4)max(abs(value)-1.0,0.0);
    uint3 rgb = uint3(v.x & 65535u, (v.x >> 16) | ((v.y & 255u) << 8), v.y >> 8);
    uint2 oct = uint2((v.z >> 16) & 31u, (v.z >> 21) | ((v.w & 3u) << 3));
    BrtcHistory t = (BrtcHistory)0;
    t.signal = float4(f16tof32(rgb & 0xFFFCu), (float)((v.w >> 2) & 1023u) / 1023.0);
    t.depth = f16tof32(v.z & 65535u);
    t.normal = BrtcHistoryUnoct(float2(oct) / 15.0 - 1.0);
    t.age = (float)((v.w >> 12) & 31u);
    t.hit = (float)(((v.w >> 17) & 63u) | (sign.x<<6) | (sign.y<<7) | (sign.z<<8) | (sign.w<<9));
    t.water = (float)(v.w >> 23);
    t.misses = (float)((rgb.x & 3u) | ((rgb.y & 1u) << 2));
    float roughCode=(float)(((rgb.y >> 1) & 1u) | ((rgb.z & 3u) << 1)) / 7.0;
    t.rough = roughCode*roughCode;
    return t;
}
float4 BrtcHistoryEnergy(float4 s)
{
    return float4(s.rgb * s.a, s.a);
}
float4 BrtcHistorySignal(float4 e)
{
    float a = saturate(e.a);
    return float4(a > 1e-5 ? max(e.rgb, 0.0) / a : float3(0,0,0), a);
}
float4 BrtcReadCompositeSignal(float2 uv)
{
#if defined(BEAMRT_COH_SSR_NO_DEBUG)
    if(uUnifiedTemporal>0.5 && uHistoryInterleave>0.5)return 0;
#endif
    float4 result = tex2Dlod(auxTex, float4(uv, 0, 0));
    if (uUnifiedTemporal > 0.5)
    {
        BrtcHistory history = BrtcUnpackHistory(auxTexTex.Load(BrtcHistoryNearestTexel(uv,gAuxSize,gSourceSize)));
        result = history.signal;
    }
    return result;
}

float4 BrtcResolveDetailHistory(PFXVertToPix IN, float2 uv, float depth,
    float3 normal, float rough, float water, float3 detailNormal, out float hit,out float nativeDetail)
{
    hit = 1023; nativeDetail = 0;
    int2 nativePixel=(int2)IN.hpos.xy;
    float3 du=gNativeRayDU,dv=gNativeRayDV;
    float3 position=IN.wsEyeRay*depth;
    float footprint=depth*max(length(du)/gAuxSize.x,length(dv)/gAuxSize.y);
    float tolerance=max(0.012,depth*projParams.y*0.0015)+footprint*0.5;
    float4 sum=0; float weight=0, best=-1; hit=1023;nativeDetail=0;
    float3 quantizedNormal=BrtcHistoryUnoct(round(BrtcHistoryOct(detailNormal)*15.0)/15.0);
    bool verticalFallback=false;
    [unroll] for(int i=0;i<6;i++)
    {
        int2 q = 0; float w = 0;
        if(i<4)BrtcHistoryGatherTap(uv,gAuxSize,gSourceSize,i,q,w);
        else
        {
            if(i==4)verticalFallback=uHistoryInterleave>0.5 && weight<0.05 && ((nativePixel.x&1)!=(nativePixel.y&1));
            if(!verticalFallback)continue;
            q=int2(nativePixel.x>>1,nativePixel.y+(i==4?-1:1));w=0.5;
        }
        if(w<1e-5)continue;
        if(any(q<0)||any(q>(int2)gAuxMaxCoord))continue;
        BrtcHistory t=BrtcUnpackHistory(auxTexTex.Load(int3(q,0)));
        if(t.age<0.5||t.depth<=1e-6||t.depth>=0.999999||abs(t.water-water)>0.5||abs(t.rough-rough)>0.30)continue;
        float agreement=dot(t.normal,normal);
        if(agreement<0.75)continue;
        float2 quv=BrtcHistoryReceiverUV(q,gAuxSize,gSourceSize);
        float3 samplePoint=(IN.wsEyeRay+du*(quv.x-uv.x)+dv*(quv.y-uv.y))*t.depth;
        float3 delta=samplePoint-position;
        float error=max(abs(dot(delta,normal)),abs(dot(delta,t.normal)));
        if(error>tolerance)continue;
        w*=exp(-error/max(tolerance,1e-6));
        sum+=BrtcHistoryEnergy(t.signal)*w;weight+=w;
        nativeDetail+=w*(1.0-smoothstep(0.998,0.9999,dot(quantizedNormal,t.normal)));
        if(t.hit<1022.5&&w*t.signal.a>best){best=w*t.signal.a;hit=t.hit;}
    }
    nativeDetail=water>0.5?1.0:nativeDetail/max(weight,1e-6);
    float4 result = BrtcHistorySignal(sum/max(weight,1e-6));
    if(uHistoryInterleave>0.5 && ((nativePixel.x&1)==(nativePixel.y&1)))
    {
        BrtcHistory exact=BrtcUnpackHistory(auxTexTex.Load(int3(nativePixel.x>>1,nativePixel.y,0)));
        hit=exact.hit; nativeDetail=0;
        result=exact.signal;
    }
    return result;
}
#endif
