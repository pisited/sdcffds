// GPU-only producer. Receiver texture comes from the matched GI receiver draw;
// mesh is the existing packed atlas, surfel positions from the same GI constants.
Texture2D<float4> meshDataTexTex : register(t0);
Texture2D<float4> receivers : register(t1);
RWTexture2D<float4> visibility : register(u0);
cbuffer Scene : register(b0) {
    float4 origin,inverseX,inverseY,inverseZ,quantMin,quantExtent;
    uint4 counts,atlas;uint4 materials[4];
};
cbuffer Frame : register(b1) {
    uint4 dimensions; // receiver width,height,surfel count,reserved
    float4 key;       // exact view/frame, geometry, surfel keys and ABI=1
    float4 surfels[32]; // position/radius from original GI draw
};
#define meshOrigin origin.xyz
#define meshInvX inverseX.xyz
#define meshInvY inverseY.xyz
#define meshInvZ inverseZ.xyz
#define meshQuantMin quantMin.xyz
#define meshQuantExtent quantExtent.xyz
#define meshNodeCount float(counts.x)
#define meshTriangleCount float(counts.y)
#define meshTriangleOffset float(counts.z)
#define meshAtlasSize float2(atlas.xy)
#define meshMaterialPolicyEnabled 1.0
#define meshMaterialModes0 float4(materials[0])
#define meshMaterialModes1 float4(materials[1])
#define meshMaterialModes2 float4(materials[2])
#define meshMaterialModes3 float4(materials[3])
#define meshVisibilityEnabled 1.0
#include "shaders/beamrt/beamrtMeshBVHCommon.h.hlsl"
[numthreads(8,8,1)]
void main(uint3 id : SV_DispatchThreadID)
{
    if(id.x>=dimensions.x || id.y>dimensions.y) return;
    if(id.y==0) { visibility[id.xy]=id.x==0 ? key : 0.0;return; }
    float4 receiver=receivers.Load(int3(id.x,id.y-1,0));
    uint blocked=0;
    if(receiver.w!=1.0 || !all(isfinite(receiver.xyz))) { visibility[id.xy]=-1.0;return; }
    [loop]for(uint i=0;i<dimensions.z;++i)
    {
        float3 delta=surfels[i].xyz-receiver.xyz;float distance=length(delta);
        if(!isfinite(distance)) { visibility[id.xy]=-1.0;return; }
        if(distance<.2) continue;
        uint visits;int hit=beamrtMeshTrace(receiver.xyz,delta/distance,distance-.08,.08,visits);
        if(hit<0) { visibility[id.xy]=-1.0;return; }
        if(hit==2) blocked|=1u<<i;
    }
    visibility[id.xy]=float4(blocked&255u,(blocked>>8)&255u,(blocked>>16)&255u,(blocked>>24)&255u);
}
