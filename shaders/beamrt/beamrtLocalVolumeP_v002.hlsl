// Experimental optically thin local haze; no native shadow-atlas visibility.
// Beauty in slot zero keeps a native passthrough from exposing the G-buffer.
#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(sceneTex,0);
uniform_sampler2D(normalTex,1);
uniform_sampler2D(depthTex,2);
cbuffer perDraw : register(b0) {
    float3 eyePosWorld;
    float volumeCount, volumeStrength, volumeDensity;
    float4 volumePosition0,volumePosition1,volumePosition2,volumePosition3;
    float4 volumeDirection0,volumeDirection1,volumeDirection2,volumeDirection3;
    float4 volumeColor0,volumeColor1,volumeColor2,volumeColor3;
    float volumeInner0,volumeInner1,volumeInner2,volumeInner3;
    POSTFX_UNIFORMS
};
#include "shaders/common/postFx/postFx.hlsl"
#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif
float3 beamrtLocalScatter(float3 ray,float endT,float4 lamp,float4 axis,float4 color,float inner) {
    float3 toLamp=lamp.xyz-eyePosWorld;
    float center=dot(toLamp,ray);
    float radius2=lamp.w*lamp.w;
    float disc=radius2-dot(toLamp,toLamp)+center*center;
    if(disc<=0) return 0;
    float root=sqrt(disc);
    float startT=max(0,center-root), stopT=min(endT,center+root);
    if(stopT<=startT) return 0;
    float ds=(stopT-startT)/8;
    float integral=0;
    [unroll] for(int i=0;i<8;i++) {
        float3 fromLamp=eyePosWorld+ray*(startT+(i+.5)*ds)-lamp.xyz;
        float d2=max(dot(fromLamp,fromLamp),.04);
        float3 direction=fromLamp*rsqrt(d2);
        float cone=smoothstep(axis.w,max(inner,axis.w+.0001),dot(direction,axis.xyz));
        float falloff=saturate(1-d2/max(radius2,.01));
        float scatteringCos=dot(direction,-ray);
        float phase=.91/(12.5663706*pow(max(1.09-.6*scatteringCos,.01),1.5));
        integral+=cone*falloff*falloff*phase/(1+.15*d2);
    }
    return max(color.rgb,0)*max(color.a,0)*integral*ds;
}
float4 mainP(PFXVertToPix IN) : SV_Target0 {
    float4 scene=tex2D(sceneTex,IN.uv0);
    if(volumeCount<.5 || volumeStrength<=0 || volumeDensity<=0) return scene;
    // processPostFxVert has already applied each slot's viewport transform.
    float depth=realToEyeLinearDepth(ndcToRealDepth(tex2D(depthTex,IN.uv2).r,projParams.zw),projParams);
    float rayLength=max(length(IN.wsEyeRay),.0001);
    float3 ray=IN.wsEyeRay/rayLength;
    float endT=min(50,rayLength*saturate(depth));
    float3 scatter=0;
    if(volumeCount>.5) scatter+=beamrtLocalScatter(ray,endT,volumePosition0,volumeDirection0,volumeColor0,volumeInner0);
    if(volumeCount>1.5) scatter+=beamrtLocalScatter(ray,endT,volumePosition1,volumeDirection1,volumeColor1,volumeInner1);
    if(volumeCount>2.5) scatter+=beamrtLocalScatter(ray,endT,volumePosition2,volumeDirection2,volumeColor2,volumeInner2);
    if(volumeCount>3.5) scatter+=beamrtLocalScatter(ray,endT,volumePosition3,volumeDirection3,volumeColor3,volumeInner3);
    return float4(hdrEncode(hdrDecode(scene.rgb)+scatter*volumeDensity*volumeStrength),scene.a);
}
PFXVertToPix mainV(PFXVert IN) { return processPostFxVert(IN); }
