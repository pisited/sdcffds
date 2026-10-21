#ifndef BEAMRT_REFLECTION_RECEIVER_HISTORY_H_HLSL
#define BEAMRT_REFLECTION_RECEIVER_HISTORY_H_HLSL

// The two RGBA32F hit atlases have equal W x H planes. Plane zero retains
// the original hit/motion contract. Plane one stores the receiver from the
// PREVIOUS color-history frame: octahedral world normal.xy, roughness.z,
// and an exact numeric RGB8 F0 integer plus one in .w. Zero means invalid.
// Descriptor texels and packed integers must use point/Load access only.
bool beamrtReceiverFinite4(float4 value)
{
    return all((asuint(value) & 0x7f800000u) != 0x7f800000u);
}

bool beamrtReceiverLogicalSizeValid(float2 size)
{
    return beamrtReceiverFinite4(float4(size, 0.0, 0.0))
        && all(size >= 1.0) && size.x <= 16384.0 && size.y <= 8192.0
        && all(size == floor(size));
}

float beamrtPackReceiverF0(float3 specular)
{
    uint3 q = uint3(round(saturate(specular) * 255.0));
    return float(q.x | (q.y << 8) | (q.z << 16)) + 1.0;
}

bool beamrtReceiverDescriptorValid(float4 descriptor)
{
    if (!beamrtReceiverFinite4(descriptor)) return false;
    return all(descriptor.xyz >= 0.0) && all(descriptor.xyz <= 1.0)
        && descriptor.w >= 1.0 && descriptor.w <= 16777216.0
        && descriptor.w == floor(descriptor.w);
}

float3 beamrtUnpackReceiverF0(float packed)
{
    uint word = uint(packed) - 1u;
    return float3(word & 255u, (word >> 8) & 255u, (word >> 16) & 255u) / 255.0;
}

float4 beamrtMakeReceiverDescriptor(float4 prepass, float3 specular,
    float receiverDepth, float farDepth)
{
    if (!beamrtReceiverFinite4(float4(prepass.xyz, receiverDepth))
        || !beamrtReceiverFinite4(float4(specular, farDepth))
        || !all(prepass.xyz >= 0.0) || !all(prepass.xyz <= 1.0)
        || !(receiverDepth > 0.0 && receiverDepth < farDepth * 0.9999)) return 0.0;
    // A black reflection or an eligible GGX zero sample still owns a valid
    // receiver. Descriptor validity is deliberately independent of ray hits.
    return float4(prepass.xy, prepass.b, beamrtPackReceiverF0(specular));
}

float beamrtReceiverHistoryConfidence(float4 descriptor, float3 normalWS,
    float roughness, float3 specular)
{
    if (!beamrtReceiverDescriptorValid(descriptor)
        || !beamrtReceiverFinite4(float4(normalWS, roughness))
        || !beamrtReceiverFinite4(float4(specular, 0.0))) return 0.0;
    float3 oldNormalWS = decodeNormalXY(descriptor.xy);
    if (!beamrtReceiverFinite4(float4(oldNormalWS, 0.0))) return 0.0;
    float normalError = 1.0 - saturate(dot(normalWS, oldNormalWS));
    float normalWeight = 1.0 - smoothstep(0.01, 0.08, normalError);
    float roughnessWeight = 1.0 - smoothstep(0.015, 0.12,
        abs(max(descriptor.z, 0.02) - max(roughness, 0.02)));
    float specularWeight = 1.0 - smoothstep(0.02, 0.20,
        length(beamrtUnpackReceiverF0(descriptor.w) - specular));
    return normalWeight * roughnessWeight * specularWeight;
}

#endif
