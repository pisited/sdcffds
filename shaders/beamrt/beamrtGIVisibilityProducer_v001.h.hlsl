// Shared pixel/compute GPU visibility producer. The native adapter and BeamNG
// PostFX backend use identical geometry queries and output encoding.
#ifndef BEAMRT_GI_VISIBILITY_PRODUCER_V001
#define BEAMRT_GI_VISIBILITY_PRODUCER_V001
#include "beamrtMeshBVHCommon.h.hlsl"
float4 beamrtGIVisibilityPixel(uint2 pixel)
{
    if(pixel.y==0) return pixel.x==0 ? beamrtGIProducerKey : 0.0;
    uint width,height;beamrtGIProducerReceivers.GetDimensions(width,height);
    if(any(uint2(width,height)!=beamrtGIProducerSize)) return -1.0;
    float4 receiver=beamrtGIProducerReceivers.Load(int3(pixel.x,pixel.y-1,0));
    uint blocked=0;
    if(receiver.w!=1.0 || !all(isfinite(receiver.xyz))) return -1.0;
    [loop]for(uint i=0;i<beamrtGIProducerCount;++i)
    {
        float3 delta=beamrtGIProducerSurfel(i).xyz-receiver.xyz;float distance=length(delta);
        if(!isfinite(distance)) return -1.0;
        if(distance<.2) continue;
        uint visits;int hit=beamrtMeshTrace(receiver.xyz,delta/distance,distance-.08,.08,visits);
        if(hit<0) return -1.0;
        if(hit==2) blocked|=1u<<i;
    }
    return float4(blocked&255u,(blocked>>8)&255u,(blocked>>16)&255u,(blocked>>24)&255u);
}
#endif
