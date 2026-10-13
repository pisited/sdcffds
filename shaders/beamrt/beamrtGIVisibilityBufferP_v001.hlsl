// Real-world mesh visibility, not final-image darkening. Engine-managed GPU RTs.
#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(receiverOriginTex,0);
uniform_sampler2D(meshDataTex,1);
cbuffer perDraw : register(b0) {
    #include "beamrtMeshBVHUniforms.h.hlsl"
    uniform float2 visibilitySize;
    uniform float4 nativeGIVisibilityKey;
    uniform float surfelCount;
    uniform float4 surfelPositionRadius0;
    uniform float4 surfelPositionRadius1;
    uniform float4 surfelPositionRadius2;
    uniform float4 surfelPositionRadius3;
    uniform float4 surfelPositionRadius4;
    uniform float4 surfelPositionRadius5;
    uniform float4 surfelPositionRadius6;
    uniform float4 surfelPositionRadius7;
    uniform float4 surfelPositionRadius8;
    uniform float4 surfelPositionRadius9;
    uniform float4 surfelPositionRadius10;
    uniform float4 surfelPositionRadius11;
    uniform float4 surfelPositionRadius12;
    uniform float4 surfelPositionRadius13;
    uniform float4 surfelPositionRadius14;
    uniform float4 surfelPositionRadius15;
    uniform float4 surfelPositionRadius16;
    uniform float4 surfelPositionRadius17;
    uniform float4 surfelPositionRadius18;
    uniform float4 surfelPositionRadius19;
    uniform float4 surfelPositionRadius20;
    uniform float4 surfelPositionRadius21;
    uniform float4 surfelPositionRadius22;
    uniform float4 surfelPositionRadius23;
    uniform float4 surfelPositionRadius24;
    uniform float4 surfelPositionRadius25;
    uniform float4 surfelPositionRadius26;
    uniform float4 surfelPositionRadius27;
    uniform float4 surfelPositionRadius28;
    uniform float4 surfelPositionRadius29;
    uniform float4 surfelPositionRadius30;
    uniform float4 surfelPositionRadius31;
    POSTFX_UNIFORMS
};
#include "shaders/common/postFx/postFx.hlsl"
float4 beamrtGIProducerSurfel(uint index) {
    if(index==0u) return surfelPositionRadius0;
    if(index==1u) return surfelPositionRadius1;
    if(index==2u) return surfelPositionRadius2;
    if(index==3u) return surfelPositionRadius3;
    if(index==4u) return surfelPositionRadius4;
    if(index==5u) return surfelPositionRadius5;
    if(index==6u) return surfelPositionRadius6;
    if(index==7u) return surfelPositionRadius7;
    if(index==8u) return surfelPositionRadius8;
    if(index==9u) return surfelPositionRadius9;
    if(index==10u) return surfelPositionRadius10;
    if(index==11u) return surfelPositionRadius11;
    if(index==12u) return surfelPositionRadius12;
    if(index==13u) return surfelPositionRadius13;
    if(index==14u) return surfelPositionRadius14;
    if(index==15u) return surfelPositionRadius15;
    if(index==16u) return surfelPositionRadius16;
    if(index==17u) return surfelPositionRadius17;
    if(index==18u) return surfelPositionRadius18;
    if(index==19u) return surfelPositionRadius19;
    if(index==20u) return surfelPositionRadius20;
    if(index==21u) return surfelPositionRadius21;
    if(index==22u) return surfelPositionRadius22;
    if(index==23u) return surfelPositionRadius23;
    if(index==24u) return surfelPositionRadius24;
    if(index==25u) return surfelPositionRadius25;
    if(index==26u) return surfelPositionRadius26;
    if(index==27u) return surfelPositionRadius27;
    if(index==28u) return surfelPositionRadius28;
    if(index==29u) return surfelPositionRadius29;
    if(index==30u) return surfelPositionRadius30;
    if(index==31u) return surfelPositionRadius31;
    return 0.0;
}
#define beamrtGIProducerKey nativeGIVisibilityKey
#define beamrtGIProducerSize (uint2)visibilitySize
#define beamrtGIProducerCount (uint)clamp(floor(surfelCount+.5),0,32)
#define beamrtGIProducerReceivers receiverOriginTexTex
#include "beamrtGIVisibilityProducer_v001.h.hlsl"
#ifdef SHADER_STAGE_VS
PFXVertToPix main(PFXVert IN) { return processPostFxVert(IN); }
#else
float4 main(PFXVertToPix IN):SV_Target0 {
    uint2 pixel=(uint2)floor(IN.hpos.xy);
    if(pixel.x>=(uint)visibilitySize.x || pixel.y>(uint)visibilitySize.y) return -1.0;
    return beamrtGIVisibilityPixel(pixel);
}
#endif
