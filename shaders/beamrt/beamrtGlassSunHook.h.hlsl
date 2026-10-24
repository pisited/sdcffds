// Additional scalar window transmission, not a final-image darkening overlay.
uniform_sampler2D(beamrtGlassSunVisibility,14);
float beamrtGlassSunTransmission(float4 hpos,float3 worldPosition)
{
    uint w,h,dw,dh;
    beamrtGlassSunVisibilityTex.GetDimensions(w,h);
    prePassDepthBufferTex.GetDimensions(dw,dh);
    if(w==0||w!=dw||h!=dh||!all(isfinite(hpos.xy))||!all(isfinite(worldPosition)))return 1;
    if(any(hpos.xy<0)||any(hpos.xy>=float2(w,h)))return 1;
    float4 value=beamrtGlassSunVisibilityTex.Load(int3(int2(hpos.xy),0));
    // XYZ is the exact main-view receiver, W=1+T. Missing/other-view data
    // must not certify a glass shadow. R32 precision is required by the producer.
    if(!all(isfinite(value))||value.w<1||value.w>2||any(abs(value.xyz-worldPosition)>.01))return 1;
    return saturate(value.w-1);
}
