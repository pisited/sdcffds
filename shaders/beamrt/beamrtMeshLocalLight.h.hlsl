// Query actual world geometry INSIDE the native point/spot light pixel pass.
// Dataset constants are immutable ShaderData defines on fresh private objects.
// No camera-depth relay, brightness override, separate local-light reconstruction
// or generic darkening of the finished image. Unknown/incomplete -> native.
uniform_sampler2D(meshDataTex,14);
#include "beamrtMeshBVHCommon.h.hlsl"
float beamrtLocalShadowFactor(float3 receiver,float3 normal,float3 lightPosition,float nativeVisibility)
{
    if(nativeVisibility<=0)return nativeVisibility;
    float3 delta=lightPosition-receiver;float distance=length(delta);
    if(distance<.16||dot(normal,delta)<=0)return nativeVisibility;
    uint visits;
    int category=beamrtMeshTrace(receiver+normal*.01,delta/distance,distance-.04,.04,visits);
    return category==2?0:nativeVisibility;
}
