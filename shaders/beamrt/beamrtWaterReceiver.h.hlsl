#ifndef BEAMRT_WATER_RECEIVER_H_HLSL
#define BEAMRT_WATER_RECEIVER_H_HLSL
// Independent geometry-only prototype. A candidate is NOT proof that the game
// rendered water at this pixel; do not substitute it into normal SSR/GI shading.
bool beamrtWaterFinite3(float3 v)
{
    return all((asuint(v) & 0x7f800000u) != 0x7f800000u);
}
float beamrtWaterPlaneDistance(float3 eye, float3 direction, float height,
    float maxDistance)
{
    float distance = -1.0;
    if (eye.z > height + 0.01 && direction.z < -0.00001)
    {
        float t = (height - eye.z) / direction.z;
        if (t > 0.02 && t <= maxDistance) distance = t;
    }
    return distance;
}
bool beamrtWaterReceiverCandidate(float3 eye, float3 eyeRay, float3 opaqueWorld,
    bool opaqueValid, float4 plane, float4 blockMin, float4 blockMax,
    float maxDistance, out float3 position, out float3 normal,
    out float distance, out float kind)
{
    position = 0.0; normal = float3(0, 0, 1); distance = 0.0; kind = 0.0;
    bool valid = beamrtWaterFinite3(eye) && beamrtWaterFinite3(eyeRay)
        && beamrtWaterFinite3(float3(maxDistance, 0, 0))
        && maxDistance >= 1.0 && maxDistance <= 1000.0;
    valid = valid && (!opaqueValid || beamrtWaterFinite3(opaqueWorld));
    float rayLength = length(eyeRay);
    valid = valid && rayLength > 0.00001 && rayLength < 10000000.0;
    if (valid)
    {
        float3 direction = eyeRay / rayLength;
        float selected = maxDistance + 1.0;
        bool planeValid = plane.y == 1.0 && beamrtWaterFinite3(plane.xyz);
        if (planeValid)
        {
            float t = beamrtWaterPlaneDistance(eye, direction, plane.x, maxDistance);
            if (t > 0.0) { selected = t; kind = 1.0; }
        }
        bool blockValid = blockMin.w == 1.0 && beamrtWaterFinite3(blockMin.xyz)
            && beamrtWaterFinite3(blockMax.xyz)
            && all(blockMax.xy - blockMin.xy > 0.04);
        if (blockValid)
        {
            float t = beamrtWaterPlaneDistance(eye, direction, blockMin.z, maxDistance);
            float2 hitXY = eye.xy + direction.xy * t;
            // Deliberately exclude the uncertain shoreline/bounds edge.
            bool inside = all(hitXY > blockMin.xy + 0.02)
                && all(hitXY < blockMax.xy - 0.02);
            if (t > 0.0 && t < selected && inside) { selected = t; kind = 2.0; }
        }
        if (kind > 0.0)
        {
            float opaqueDistance = dot(opaqueWorld - eye, direction);
            bool foregroundClear = !opaqueValid || selected + 0.02 < opaqueDistance;
            if (foregroundClear)
            {
                position = eye + direction * selected;
                distance = selected;
            }
            else kind = 0.0;
        }
    }
    return kind > 0.0;
}
#endif
