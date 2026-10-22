// Diagnostic only. No beauty multiplication, native atlas guesses or GI input.
#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(sceneTex,0);
uniform_sampler2D(normalTex,1);
uniform_sampler2D(depthTex,2);
cbuffer perDraw:register(b0)
{
    float3 eyePosWorld;
    float4 diagnosticPosition,diagnosticDirection,diagnosticColor;
    float diagnosticMode,diagnosticInner,diagnosticSpot,diagnosticEnabled;
    POSTFX_UNIFORMS
};
#include "shaders/common/postFx/postFx.hlsl"
#ifdef SHADER_STAGE_VS
#define mainV main
#else
#define mainP main
#endif
// Same perspective eye-ray basis used by BeamRT's existing screen tracer.
bool visibilityProject(float3 p,float3 ray,float3 du,float3 dv,float2 uv,out float2 projected,out float depth)
{
    float determinant=dot(ray,cross(du,dv));projected=0;depth=0;
    if(abs(determinant)<1e-8)return false;
    depth=dot(p,cross(du,dv))/determinant;
    if(depth<=1e-6)return false;
    projected=uv+float2(dot(ray,cross(p,dv)),dot(ray,cross(du,p)))/(determinant*depth);
    return all(isfinite(projected))&&isfinite(depth);
}
// 32 fixed samples: finding a plausible visible surface is evidence only.
// A miss, sky, leaving the viewport or insufficient reach NEVER means clear.
bool screenBlocker(float3 receiver,float3 normal,float3 ray,float3 du,float3 dv,float2 uv)
{
    float3 origin=receiver+normal*.035;
    float3 delta=diagnosticPosition.xyz-origin;float distance=length(delta);
    if(distance<.12)return false;
    // Bounded nearby coverage. Long segments remain explicitly unknown.
    float reach=min(distance-.04,12.0);
    [loop] for(int i=0;i<32;i++)
    {
        float travel=.06+(reach-.06)*(i+.5)/32.0;
        float3 relative=origin+delta/distance*travel-eyePosWorld;
        float2 sampleUv;float sampleDepth;
        if(!visibilityProject(relative,ray,du,dv,uv,sampleUv,sampleDepth))return false;
        float2 viewUv=(sampleUv-rtParams1.xy)/rtParams1.zw;
        if(any(viewUv<=.001)||any(viewUv>=.999)||sampleDepth>=.9999)return false;
        float2 depthUv=viewportCoordToRenderTarget(viewUv,rtParams2);
        float4 surface=decodeGBuffer(TEX_SAMPLER(depthTex),TEX_SAMPLER(normalTex),depthUv,projParams);
        if(!all(isfinite(surface))||surface.w<=0||surface.w>=.9999)continue;
        float3 sampleRay=ray+du*(sampleUv.x-uv.x)+dv*(sampleUv.y-uv.y);
        float gap=(sampleDepth-surface.w)*length(sampleRay);
        // Single-layer depth has no measured thickness. Fixed 12 cm is only
        // a probe tolerance; do not export it as full geometry visibility.
        if(gap>.015&&gap<.12&&travel>.08)return true;
    }
    return false;
}
float4 mainP(PFXVertToPix IN):SV_Target0
{
    float4 beauty=tex2D(sceneTex,IN.uv0);
    if(diagnosticMode<.5)return beauty; // neutral fallback during failed cleanup
    // decodeGBuffer's combined texture overload uses one UV for both inputs.
    // Refuse an unsupported offset/scale mismatch rather than mix receivers.
    if(any(abs(rtParams1-rtParams2)>1e-6)||any(rtParams1.zw<=0))return beauty;
    float dx=ddx(IN.uv1.x),dy=ddy(IN.uv1.y);
    float3 du=ddx(IN.wsEyeRay)/max(abs(dx),1e-8)*sign(dx);
    float3 dv=ddy(IN.wsEyeRay)/max(abs(dy),1e-8)*sign(dy);
    if(!all(isfinite(IN.wsEyeRay))||!all(isfinite(du))||!all(isfinite(dv)))return beauty;
    float4 receiver=decodeGBuffer(TEX_SAMPLER(depthTex),TEX_SAMPLER(normalTex),IN.uv2,projParams);
    if(!all(isfinite(receiver))||receiver.w<=0||receiver.w>=.9999)return float4(.025,.025,.025,beauty.a);
    // Native visibility and unknown enabled state have their own unavailable code.
    if(diagnosticMode>3.5||diagnosticEnabled<0)return float4(.65,0,.65,beauty.a);
    if(diagnosticEnabled<.5)return float4(.04,.04,.04,beauty.a);
    float3 world=eyePosWorld+IN.wsEyeRay*receiver.w;
    float3 delta=diagnosticPosition.xyz-world;float d2=dot(delta,delta);
    if(!all(isfinite(world))||d2<1e-6)return beauty;
    float distance=sqrt(d2);float3 towardLight=delta/distance;
    float cone=1;
    if(diagnosticSpot>.5)
    {
        float cosine=dot(-towardLight,diagnosticDirection.xyz);
        cone=saturate((cosine-diagnosticDirection.w)/max(diagnosticInner-diagnosticDirection.w,1e-5));
    }
    float nDotL=saturate(dot(receiver.xyz,towardLight));
    // Native clustered falloff family, not a claim of calibrated engine intensity.
    float t=d2/max(diagnosticPosition.w*diagnosticPosition.w,1e-6);
    float window=saturate(1-t*t);
    float potential=nDotL*cone*window*window/max(d2,1e-6)*max(diagnosticColor.a,0);
    potential*=max(diagnosticColor.r,max(diagnosticColor.g,diagnosticColor.b));
    if(distance>=diagnosticPosition.w||potential<=0)return float4(.04,.04,.04,beauty.a);
    if(diagnosticMode<1.5)
    {
        // Fixed diagnostic-only display gain. Not a beauty exposure adjustment.
        float value=saturate(log2(1+64*potential)/8);
        return float4(value,value,value,beauty.a);
    }
    if(diagnosticMode<2.5)return float4(towardLight*.5+.5,beauty.a);
    bool hit=screenBlocker(world,receiver.xyz,IN.wsEyeRay,du,dv,IN.uv1);
    return float4(hit?float3(1,.04,.02):float3(1,.55,.02),beauty.a);
}
PFXVertToPix mainV(PFXVert IN){return processPostFxVert(IN);}
