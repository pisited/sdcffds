#ifndef BEAMRT_RECEIVER_COLOR_H_HLSL
#define BEAMRT_RECEIVER_COLOR_H_HLSL

// Experimental material-color estimate, NOT measured diffuse albedo. Remove
// incident light color before tinting arriving GI; otherwise a warm lamp can
// tint both the bounce source and the receiver with the same orange twice.
float3 beamrtDelitReceiverChroma(float3 scene, float3 directLight)
{
    const float3 weights = float3(0.2126, 0.7152, 0.0722);
    scene = max(scene, 0.0);
    directLight = max(directLight, 0.0);
    float directY = dot(directLight, weights);
    float scalar = saturate(dot(scene, weights) / max(directY, 0.04));
    float3 estimate = saturate(scene / max(directLight, 0.04));
    float3 confidence = smoothstep(0.02, 0.15, directLight);
    float3 stable = lerp(scalar.xxx, estimate, confidence);
    float y = dot(stable, weights);
    // No color evidence in darkness: neutral, rather than inventing brown.
    float evidence = smoothstep(0.002, 0.02, y);
    // Unit luminance separates receiver color from the scalar reflectance.
    // This is not a global desaturation or indirect-light brightness knob.
    return lerp(float3(1.0, 1.0, 1.0), stable / max(y, 0.0001), evidence);
}

#endif
