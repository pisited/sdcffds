// Included only by a generated copy of the installed vector-light shader.
// Apply before native direct diffuse/specular shading, never to final color.
uniform_sampler2D(beamrtMeshSunVisibility,14);
float beamrtMeshSunFactor(float4 hpos,float3 worldPosition)
{
    uint width,height;beamrtMeshSunVisibilityTex.GetDimensions(width,height);
    uint depthWidth,depthHeight;prePassDepthBufferTex.GetDimensions(depthWidth,depthHeight);
    // No upsampling, stale resolution or missing named target accepted.
    if(width!=depthWidth||height!=depthHeight||width==0)return 1;
    int2 pixel=int2(hpos.xy);
    if(any(pixel<0)||pixel.x>=(int)width||pixel.y>=(int)height)return 1;
    float4 value=beamrtMeshSunVisibilityTex.Load(int3(pixel,0));
    // Receiver identity also rejects main-camera masks in reflection captures.
    // A missing/unbound resource returns zero, which is NOT a blocked sentinel.
    if(value.w!=2||any(abs(value.xyz-worldPosition)>.01))return 1;
    return 0;
}
