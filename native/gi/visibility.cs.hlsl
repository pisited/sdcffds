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
float4 beamrtGIProducerSurfel(uint index) { return surfels[index]; }
#define beamrtGIProducerKey key
#define beamrtGIProducerSize dimensions.xy
#define beamrtGIProducerCount dimensions.z
#define beamrtGIProducerReceivers receivers
#include "shaders/beamrt/beamrtGIVisibilityProducer_v001.h.hlsl"
[numthreads(8,8,1)]
void main(uint3 id : SV_DispatchThreadID)
{
    if(id.x>=dimensions.x || id.y>dimensions.y) return;
    visibility[id.xy]=beamrtGIVisibilityPixel(id.xy);
}
