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
bool visibilityDepthPosition(float2 uv,float3 ray,out float3 world)
{
    world=0;
    float2 viewUv=(uv-rtParams1.xy)/rtParams1.zw;
    if(any(viewUv<=.001)||any(viewUv>=.999))return false;
    float4 surface=decodeGBuffer(TEX_SAMPLER(depthTex),TEX_SAMPLER(normalTex),uv,projParams);
    if(!all(isfinite(surface))||surface.w<=0||surface.w>=.9999)return false;
    world=eyePosWorld+ray*surface.w;
    return all(isfinite(world));
}
// Geometry-derived frame: choose the nearer valid depth neighbour per axis.
// Bump/shading normals do not determine the offset or receiver-plane rejection.
// Missing/discontinuous geometry gives UNKNOWN, not a guessed shadow.
bool visibilityReceiverFrame(float3 receiver,float3 ray,float3 du,float3 dv,float2 uv,float2 size,
    out float3 normal,out float normalBias,out float planeTolerance)
{
    normal=0;normalBias=0;planeTolerance=0;
    float3 left,right,up,down;
    float2 pixel=1/size;
    bool hasLeft=visibilityDepthPosition(uv-float2(pixel.x,0),ray-du*pixel.x,left);
    bool hasRight=visibilityDepthPosition(uv+float2(pixel.x,0),ray+du*pixel.x,right);
    bool hasUp=visibilityDepthPosition(uv-float2(0,pixel.y),ray-dv*pixel.y,up);
    bool hasDown=visibilityDepthPosition(uv+float2(0,pixel.y),ray+dv*pixel.y,down);
    if((!hasLeft&&!hasRight)||(!hasUp&&!hasDown))return false;
    float3 tx=right-receiver,opposite=receiver-left;
    if(!hasRight||(hasLeft&&dot(opposite,opposite)<dot(tx,tx)))tx=opposite;
    float3 ty=down-receiver;opposite=receiver-up;
    if(!hasDown||(hasUp&&dot(opposite,opposite)<dot(ty,ty)))ty=opposite;
    float lx=dot(tx,tx),ly=dot(ty,ty);
    if(!isfinite(lx)||!isfinite(ly)||min(lx,ly)<1e-12)return false;
    // A depth discontinuity must not turn into a giant offset/tilted plane.
    float depth=length(receiver-eyePosWorld)/max(length(ray),1e-6);
    float expected=max(length(du)*pixel.x,length(dv)*pixel.y)*depth;
    if(max(lx,ly)>pow(max(.25,expected*8),2))return false;
    float3 n=cross(tx,ty);float area=dot(n,n);
    if(!all(isfinite(n))||area<lx*ly*1e-6)return false;
    normal=n*rsqrt(area);
    if(dot(normal,-ray)<0)normal=-normal;
    float footprint=sqrt(min(lx,ly));
    normalBias=clamp(.004+.1*footprint,.005,.025);
    planeTolerance=clamp(.002+.05*footprint,.003,.015);
    return true;
}
bool visibilitySeparateReceiver(float3 receiver,float3 candidate,float3 normal,float tolerance)
{
    // Outgoing light rays cannot be blocked by the receiving plane itself or
    // its back side. A separate parallel surface ABOVE it is still eligible.
    return dot(candidate-receiver,normal)>tolerance;
}
bool visibilityRaySample(float3 origin,float3 direction,float travel,float3 ray,float3 du,float3 dv,
    float2 uv,float2 size,out float gap,out float3 candidate)
{
    gap=0;candidate=0;
    float3 relative=origin+direction*travel-eyePosWorld;
    float2 sampleUv;float sampleDepth;
    if(!visibilityProject(relative,ray,du,dv,uv,sampleUv,sampleDepth))return false;
    // Point depth and reconstruction must refer to the SAME texel centre.
    sampleUv=(floor(sampleUv*size)+.5)/size;
    float2 viewUv=(sampleUv-rtParams1.xy)/rtParams1.zw;
    if(any(viewUv<=.001)||any(viewUv>=.999)||sampleDepth>=.9999)return false;
    float2 depthUv=viewportCoordToRenderTarget(viewUv,rtParams2);
    float4 surface=decodeGBuffer(TEX_SAMPLER(depthTex),TEX_SAMPLER(normalTex),depthUv,projParams);
    if(!all(isfinite(surface))||surface.w<=0||surface.w>=.9999)return false;
    float3 sampleRay=ray+du*(sampleUv.x-uv.x)+dv*(sampleUv.y-uv.y);
    candidate=eyePosWorld+sampleRay*surface.w;
    gap=(sampleDepth-surface.w)*length(sampleRay);
    return isfinite(gap)&&all(isfinite(candidate));
}
bool visibilityCrossed(float a,float b)
{
    // Opaque visible surfaces are two-sided occluders for this probe. A ray
    // from beneath a car can cross its visible roof in either depth direction.
    return (a<=0&&b>=0)||(a>=0&&b<=0);
}
bool visibilityRefine(float3 receiver,float3 normal,float planeTolerance,float3 origin,float3 direction,
    float low,float high,float lowGap,float highGap,float3 lowCandidate,float3 highCandidate,
    float3 ray,float3 du,float3 dv,float2 uv,float2 size)
{
    [loop] for(int refine=0;refine<6;refine++)
    {
        float mid=.5*(low+high),midGap;float3 midCandidate;
        // Never bracket across missing/sky data or call it clear.
        if(!visibilityRaySample(origin,direction,mid,ray,du,dv,uv,size,midGap,midCandidate))return false;
        if(visibilityCrossed(lowGap,midGap))
        {high=mid;highGap=midGap;highCandidate=midCandidate;}
        else {low=mid;lowGap=midGap;lowCandidate=midCandidate;}
    }
    float gap=abs(lowGap)<abs(highGap)?lowGap:highGap;
    float3 candidate=abs(lowGap)<abs(highGap)?lowCandidate:highCandidate;
    // A sign flip at a silhouette/depth discontinuity is not automatically a
    // surface intersection. Require convergence to within 2 cm of sampled depth.
    return abs(gap)<=.02&&visibilitySeparateReceiver(receiver,candidate,normal,planeTolerance);
}
// 32 coarse samples plus at most two 6-step refinements, not isolated hit bands.
// A miss, sky, leaving the viewport or insufficient reach NEVER means clear.
bool screenBlocker(float3 receiver,float3 ray,float3 du,float3 dv,float2 uv)
{
    uint width,height;depthTexTex.GetDimensions(width,height);
    if(width==0||height==0)return false;
    float2 size=float2(width,height);
    float3 normal;float normalBias,planeTolerance;
    if(!visibilityReceiverFrame(receiver,ray,du,dv,uv,size,normal,normalBias,planeTolerance))return false;
    if(dot(normal,diagnosticPosition.xyz-receiver)<=0)return false;
    float3 origin=receiver+normal*normalBias;
    float3 delta=diagnosticPosition.xyz-origin;float distance=length(delta);
    if(distance<.12)return false;
    // Bounded nearby coverage. Long segments remain explicitly unknown.
    float reach=min(distance-.04,12.0);
    float3 direction=delta/distance;
    bool previousValid=false;float previousTravel=0,previousGap=0;
    float3 previousCandidate=0;uint refinements=0;
    [loop] for(int i=0;i<32;i++)
    {
        float travel=.06+(reach-.06)*i/31.0;
        float gap;float3 candidate;
        bool valid=visibilityRaySample(origin,direction,travel,ray,du,dv,uv,size,gap,candidate);
        if(!valid){previousValid=false;continue;}
        if(previousValid&&visibilityCrossed(previousGap,gap)
            &&(visibilitySeparateReceiver(receiver,previousCandidate,normal,planeTolerance)
               ||visibilitySeparateReceiver(receiver,candidate,normal,planeTolerance)))
        {
            refinements++;
            if(visibilityRefine(receiver,normal,planeTolerance,origin,direction,
                previousTravel,travel,previousGap,gap,previousCandidate,candidate,ray,du,dv,uv,size))return true;
            if(refinements>=2)return false; // budget exhausted: UNKNOWN
        }
        previousValid=true;previousTravel=travel;previousGap=gap;previousCandidate=candidate;
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
    bool hit=screenBlocker(world,IN.wsEyeRay,du,dv,IN.uv1);
    return float4(hit?float3(1,.04,.02):float3(1,.55,.02),beauty.a);
}
PFXVertToPix mainV(PFXVert IN){return processPostFxVert(IN);}
