// Experimental optically thin local haze; no native shadow-atlas visibility.
// Beauty in slot zero keeps a native passthrough from exposing the G-buffer.
#include "shaders/common/postFx/postFx.h.hlsl"
uniform_sampler2D(sceneTex,0);
uniform_sampler2D(normalTex,1);
uniform_sampler2D(depthTex,2);
cbuffer perDraw : register(b0) {
    float3 eyePosWorld;
    float vehicleCount;
    float4 vehiclePosition0,vehiclePosition1,vehiclePosition2,vehiclePosition3;
    float4 vehicleDirection0,vehicleDirection1,vehicleDirection2,vehicleDirection3;
    float4 vehicleColor0,vehicleColor1,vehicleColor2,vehicleColor3;
    float vehicleInner0,vehicleInner1,vehicleInner2,vehicleInner3;
    float emitterCount,emissiveGain,emissiveRange;
    float4 emitterBounds0,emitterBounds1,emitterColor0,emitterColor1;
    float4 emitterPoint0_0,emitterPoint0_1,emitterPoint0_2,emitterPoint0_3;
    float4 emitterPoint1_0,emitterPoint1_1,emitterPoint1_2,emitterPoint1_3;
    float4 emitterNormal0_0,emitterNormal0_1,emitterNormal0_2,emitterNormal0_3;
    float4 emitterNormal1_0,emitterNormal1_1,emitterNormal1_2,emitterNormal1_3;
    float volumeCount, volumeStrength, volumeDensity, volumeDistance;
    float4 volumePosition0,volumePosition1,volumePosition2,volumePosition3,volumePosition4,volumePosition5,volumePosition6,volumePosition7;
    float4 volumeDirection0,volumeDirection1,volumeDirection2,volumeDirection3,volumeDirection4,volumeDirection5,volumeDirection6,volumeDirection7;
    float4 volumeColor0,volumeColor1,volumeColor2,volumeColor3,volumeColor4,volumeColor5,volumeColor6,volumeColor7;
    float volumeInner0,volumeInner1,volumeInner2,volumeInner3,volumeInner4,volumeInner5,volumeInner6,volumeInner7;
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
// Vehicle-only support clipping: integrate inside the actual positive cone,
// not eight widely spaced samples across its enclosing sphere.
bool beamrtVehicleInterval(float3 ray,float endT,float4 lamp,float4 axis,
 out float startT,out float stopT) {
    float3 q=eyePosWorld-lamp.xyz;
    float b=dot(q,ray),c=dot(q,q)-lamp.w*lamp.w;
    float disc=b*b-c;
    startT=0;stopT=0;
    if(disc<=0) return false;
    float root=sqrt(disc);
    startT=max(0,-b-root);stopT=min(endT,-b+root);
    if(stopT<=startT) return false;
    if(axis.w<0) return true; // actual native point-light prop
    float z=dot(q,axis.xyz),dz=dot(ray,axis.xyz);
    if(abs(dz)<1e-6) { if(z<=0) return false; }
    else if(dz>0) startT=max(startT,-z/dz);
    else stopT=min(stopT,-z/dz);
    if(stopT<=startT) return false;
    float cos2=axis.w*axis.w;
    float a=dz*dz-cos2;
    float qb=2*(z*dz-cos2*b),qc=z*z-cos2*dot(q,q);
    if(abs(a)<1e-6) {
        if(abs(qb)<1e-6) { if(qc<0) return false; }
        else if(qb>0) startT=max(startT,-qc/qb);
        else stopT=min(stopT,-qc/qb);
    } else {
        float cd=qb*qb-4*a*qc;
        if(cd<0) {
            float mid=.5*(startT+stopT);
            if((a*mid+qb)*mid+qc<0) return false;
        } else {
            // Stable roots avoid cancellation near a grazing/parallel ray.
            float qr=-.5*(qb+(qb>=0 ? 1 : -1)*sqrt(max(cd,0)));
            float r0=qr/a,r1=abs(qr)>1e-12 ? qc/qr : r0;
            float lo=min(r0,r1),hi=max(r0,r1);
            if(a<0) { startT=max(startT,lo);stopT=min(stopT,hi); }
            else if(startT<lo) stopT=min(stopT,lo);
            else startT=max(startT,hi);
        }
    }
    return stopT>startT;
}
float3 beamrtVehicleScatter(float3 ray,float endT,float4 lamp,float4 axis,float4 color,float inner) {
    if(color.a<=0) return 0;
    float startT,stopT;
    if(!beamrtVehicleInterval(ray,endT,lamp,axis,startT,stopT)) return 0;
    // Sixteen deterministic samples over only the contributing segment.
    // The continuous angular edge is evaluated at every sample.
    float ds=(stopT-startT)/16,integral=0;
    [unroll] for(int j=0;j<16;j++) {
        float3 delta=eyePosWorld+ray*(startT+(j+.5)*ds)-lamp.xyz;
        float d2=max(dot(delta,delta),.04);
        float3 direction=delta*rsqrt(d2);
        float cone=axis.w<0 ? 1 : smoothstep(axis.w,max(inner,axis.w+.0001),dot(direction,axis.xyz));
        float falloff=saturate(1-d2/max(lamp.w*lamp.w,.01));
        float phase=.91/(12.5663706*pow(max(1.09-.6*dot(direction,-ray),.01),1.5));
        integral+=cone*falloff*falloff*phase/(1+.15*d2);
    }
    return max(color.rgb,0)*color.a*integral*ds;
}
// Finite, geometry-oriented area quadrature, not a guessed point light.
// No source-to-scatter visibility: hidden blockers can leak. Haze only.
float beamrtAreaSample(float3 world,float3 ray,float3 emitterPosition,float4 normalArea) {
    float3 delta=world-emitterPosition;
    float d2=dot(delta,delta);
    float3 direction=delta*rsqrt(max(d2,1e-6));
    float cosine=dot(normalArea.xyz,direction);
    cosine=normalArea.w<0 ? abs(cosine) : max(cosine,0);
    float window=saturate(1-d2/max(emissiveRange*emissiveRange,.01));
    float phase=.91/(12.5663706*pow(max(1.09-.6*dot(direction,-ray),.01),1.5));
    // Finite patch bound avoids a centroid singularity; this is coarse quadrature.
    float solidAngle=min(6.2831853,abs(normalArea.w)*cosine/max(d2,.04));
    return solidAngle*window*window*phase;
}
float3 beamrtAreaScatter(float3 ray,float endT,float4 bounds,float4 color,
 float4 p0,float4 p1,float4 p2,float4 p3,float4 n0,float4 n1,float4 n2,float4 n3) {
    float3 offset=bounds.xyz-eyePosWorld;
    float center=dot(offset,ray);
    float disc=bounds.w*bounds.w-dot(offset,offset)+center*center;
    if(disc<=0) return 0;
    float root=sqrt(disc);
    float startT=max(0,center-root),stopT=min(endT,center+root);
    if(stopT<=startT) return 0;
    float ds=(stopT-startT)/4,integral=0;
    [unroll] for(int j=0;j<4;j++) {
        float3 world=eyePosWorld+ray*(startT+(j+.5)*ds);
        integral+=beamrtAreaSample(world,ray,p0.xyz,n0)+beamrtAreaSample(world,ray,p1.xyz,n1)
                 +beamrtAreaSample(world,ray,p2.xyz,n2)+beamrtAreaSample(world,ray,p3.xyz,n3);
    }
    return max(color.rgb,0)*max(emissiveGain,0)*integral*ds;
}
float4 mainP(PFXVertToPix IN) : SV_Target0 {
    float4 scene=tex2D(sceneTex,IN.uv0);
    if((volumeCount<.5 && emitterCount<.5 && vehicleCount<.5) || volumeStrength<=0 || volumeDensity<=0) return scene;
    // processPostFxVert has already applied each slot's viewport transform.
    float depth=realToEyeLinearDepth(ndcToRealDepth(tex2D(depthTex,IN.uv2).r,projParams.zw),projParams);
    float rayLength=max(length(IN.wsEyeRay),.0001);
    float3 ray=IN.wsEyeRay/rayLength;
    float endT=min(volumeDistance,rayLength*saturate(depth));
    float3 scatter=0;
    if(volumeCount>.5) scatter+=beamrtLocalScatter(ray,endT,volumePosition0,volumeDirection0,volumeColor0,volumeInner0);
    if(volumeCount>1.5) scatter+=beamrtLocalScatter(ray,endT,volumePosition1,volumeDirection1,volumeColor1,volumeInner1);
    if(volumeCount>2.5) scatter+=beamrtLocalScatter(ray,endT,volumePosition2,volumeDirection2,volumeColor2,volumeInner2);
    if(volumeCount>3.5) scatter+=beamrtLocalScatter(ray,endT,volumePosition3,volumeDirection3,volumeColor3,volumeInner3);
    if(volumeCount>4.5) scatter+=beamrtLocalScatter(ray,endT,volumePosition4,volumeDirection4,volumeColor4,volumeInner4);
    if(volumeCount>5.5) scatter+=beamrtLocalScatter(ray,endT,volumePosition5,volumeDirection5,volumeColor5,volumeInner5);
    if(volumeCount>6.5) scatter+=beamrtLocalScatter(ray,endT,volumePosition6,volumeDirection6,volumeColor6,volumeInner6);
    if(volumeCount>7.5) scatter+=beamrtLocalScatter(ray,endT,volumePosition7,volumeDirection7,volumeColor7,volumeInner7);
    if(vehicleCount>0.5) scatter+=beamrtVehicleScatter(ray,endT,vehiclePosition0,vehicleDirection0,vehicleColor0,vehicleInner0);
    if(vehicleCount>1.5) scatter+=beamrtVehicleScatter(ray,endT,vehiclePosition1,vehicleDirection1,vehicleColor1,vehicleInner1);
    if(vehicleCount>2.5) scatter+=beamrtVehicleScatter(ray,endT,vehiclePosition2,vehicleDirection2,vehicleColor2,vehicleInner2);
    if(vehicleCount>3.5) scatter+=beamrtVehicleScatter(ray,endT,vehiclePosition3,vehicleDirection3,vehicleColor3,vehicleInner3);
    if(emitterCount>.5) scatter+=beamrtAreaScatter(ray,endT,emitterBounds0,emitterColor0,
      emitterPoint0_0,emitterPoint0_1,emitterPoint0_2,emitterPoint0_3,
      emitterNormal0_0,emitterNormal0_1,emitterNormal0_2,emitterNormal0_3);
    if(emitterCount>1.5) scatter+=beamrtAreaScatter(ray,endT,emitterBounds1,emitterColor1,
      emitterPoint1_0,emitterPoint1_1,emitterPoint1_2,emitterPoint1_3,
      emitterNormal1_0,emitterNormal1_1,emitterNormal1_2,emitterNormal1_3);
    return float4(hdrEncode(hdrDecode(scene.rgb)+scatter*volumeDensity*volumeStrength),scene.a);
}
PFXVertToPix mainV(PFXVert IN) { return processPostFxVert(IN); }
