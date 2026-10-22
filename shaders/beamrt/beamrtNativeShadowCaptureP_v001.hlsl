// Runs immediately after native lighting, before lightinfo's lifetime ends.
// The child PFXTexGenOnDemand owns the snapshot consumed by the late display.
#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(receiverTex,0);
uniform_sampler2D(nativeSpecTex,1);
uniform_sampler2D(nativeFrameTex,2);
cbuffer perDraw:register(b0){float nativeShadowEpoch;float nativeScheduledEpoch;POSTFX_UNIFORMS};
#include "shaders/common/postFx/postFx.hlsl"
#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif
// (native alpha, CPU epoch, failure stage, snapshot signature).
float4 relayFailure(uint stage){return float4(0,nativeShadowEpoch,stage,.625);}
float4 mainP(PFXVertToPix IN):SV_Target0
{
    if(nativeShadowEpoch<32)return 0;
    if(nativeScheduledEpoch!=nativeShadowEpoch)return relayFailure(13);
    uint w,h;nativeFrameTexTex.GetDimensions(w,h);
    if(w!=1||h!=1)return relayFailure(1);
    float4 frame=nativeFrameTexTex.Load(int3(0,0,0));
    if(!all(isfinite(frame)))return relayFailure(2);
    if(frame.y!=.375||frame.z!=.625||frame.w!=1)return relayFailure(3);
    if(frame.x!=nativeShadowEpoch)return relayFailure(4);
    uint sw,sh,rw,rh;nativeSpecTexTex.GetDimensions(sw,sh);receiverTexTex.GetDimensions(rw,rh);
    // Compare two render-resolution inputs, NOT a late/upscaled beauty buffer.
    if(sw!=rw||sh!=rh||sw<=1||sh<=1)return relayFailure(5);
    float packed=tex2D(nativeSpecTex,IN.uv1).a;
    if(!isfinite(packed))return relayFailure(6);
    uint bits=f32tof16(packed),epoch=bits>>5,code=bits&31;
    if(epoch!=(uint)nativeShadowEpoch)return float4(0,nativeShadowEpoch,0,.625); // unknown
    if(code>=16)return relayFailure(7);
    return float4(packed,nativeShadowEpoch,12,.625); // candidate, late reader rechecks packet
}
PFXVertToPix mainV(PFXVert IN){return processPostFxVert(IN);}
