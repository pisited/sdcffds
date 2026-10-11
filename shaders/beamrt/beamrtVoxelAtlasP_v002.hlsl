#include "beamrtDebug.h.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

bool beamrtVoxelBoxSurface(float3 worldPosition, float shellThickness, int index)
{
    float4 centers[16] = {
        geometryObbCenterHalfX0, geometryObbCenterHalfX1, geometryObbCenterHalfX2, geometryObbCenterHalfX3,
        geometryObbCenterHalfX4, geometryObbCenterHalfX5, geometryObbCenterHalfX6, geometryObbCenterHalfX7,
        geometryObbCenterHalfX8, geometryObbCenterHalfX9, geometryObbCenterHalfX10, geometryObbCenterHalfX11,
        geometryObbCenterHalfX12, geometryObbCenterHalfX13, geometryObbCenterHalfX14, geometryObbCenterHalfX15
    };
    float4 axisXHalfY[16] = {
        geometryObbAxisXHalfY0, geometryObbAxisXHalfY1, geometryObbAxisXHalfY2, geometryObbAxisXHalfY3,
        geometryObbAxisXHalfY4, geometryObbAxisXHalfY5, geometryObbAxisXHalfY6, geometryObbAxisXHalfY7,
        geometryObbAxisXHalfY8, geometryObbAxisXHalfY9, geometryObbAxisXHalfY10, geometryObbAxisXHalfY11,
        geometryObbAxisXHalfY12, geometryObbAxisXHalfY13, geometryObbAxisXHalfY14, geometryObbAxisXHalfY15
    };
    float4 axisYHalfZ[16] = {
        geometryObbAxisYHalfZ0, geometryObbAxisYHalfZ1, geometryObbAxisYHalfZ2, geometryObbAxisYHalfZ3,
        geometryObbAxisYHalfZ4, geometryObbAxisYHalfZ5, geometryObbAxisYHalfZ6, geometryObbAxisYHalfZ7,
        geometryObbAxisYHalfZ8, geometryObbAxisYHalfZ9, geometryObbAxisYHalfZ10, geometryObbAxisYHalfZ11,
        geometryObbAxisYHalfZ12, geometryObbAxisYHalfZ13, geometryObbAxisYHalfZ14, geometryObbAxisYHalfZ15
    };

    float3 axisX = normalize(axisXHalfY[index].xyz);
    float3 axisY = normalize(axisYHalfZ[index].xyz);
    float3 axisZ = normalize(cross(axisX, axisY));
    float3 halfExtent = max(float3(centers[index].w, axisXHalfY[index].w, axisYHalfZ[index].w), 0.0001);
    float3 delta = worldPosition - centers[index].xyz;
    float3 localPosition = abs(float3(dot(delta, axisX), dot(delta, axisY), dot(delta, axisZ)));
    if (any(localPosition > halfExtent + shellThickness))
    {
        return false;
    }
    float3 faceDistance = abs(halfExtent - localPosition);
    return min(faceDistance.x, min(faceDistance.y, faceDistance.z)) <= shellThickness;
}

bool beamrtVoxelSurfelSurface(float3 worldPosition, float shellThickness, int index)
{
    float4 positions[32] = {
        surfelPositionRadius0, surfelPositionRadius1, surfelPositionRadius2, surfelPositionRadius3,
        surfelPositionRadius4, surfelPositionRadius5, surfelPositionRadius6, surfelPositionRadius7,
        surfelPositionRadius8, surfelPositionRadius9, surfelPositionRadius10, surfelPositionRadius11,
        surfelPositionRadius12, surfelPositionRadius13, surfelPositionRadius14, surfelPositionRadius15,
        surfelPositionRadius16, surfelPositionRadius17, surfelPositionRadius18, surfelPositionRadius19,
        surfelPositionRadius20, surfelPositionRadius21, surfelPositionRadius22, surfelPositionRadius23,
        surfelPositionRadius24, surfelPositionRadius25, surfelPositionRadius26, surfelPositionRadius27,
        surfelPositionRadius28, surfelPositionRadius29, surfelPositionRadius30, surfelPositionRadius31
    };
    float4 normals[32] = {
        surfelNormalSource0, surfelNormalSource1, surfelNormalSource2, surfelNormalSource3,
        surfelNormalSource4, surfelNormalSource5, surfelNormalSource6, surfelNormalSource7,
        surfelNormalSource8, surfelNormalSource9, surfelNormalSource10, surfelNormalSource11,
        surfelNormalSource12, surfelNormalSource13, surfelNormalSource14, surfelNormalSource15,
        surfelNormalSource16, surfelNormalSource17, surfelNormalSource18, surfelNormalSource19,
        surfelNormalSource20, surfelNormalSource21, surfelNormalSource22, surfelNormalSource23,
        surfelNormalSource24, surfelNormalSource25, surfelNormalSource26, surfelNormalSource27,
        surfelNormalSource28, surfelNormalSource29, surfelNormalSource30, surfelNormalSource31
    };

    float3 normal = normalize(normals[index].xyz);
    float3 delta = worldPosition - positions[index].xyz;
    float planeDistance = abs(dot(delta, normal));
    float3 tangentDelta = delta - normal * dot(delta, normal);
    float radius = max(positions[index].w, shellThickness);
    return planeDistance <= shellThickness && dot(tangentDelta, tangentDelta) <= radius * radius;
}

// A camera-centered 32^3 scene occupancy volume packed into a 256x128 target.
// OBB shells provide broad coverage and detailed raycast surfels correct the
// surfaces that would otherwise be represented only by a coarse object bound.
float4 mainP(PFXVertToPix IN) : SV_Target0
{
    uint2 pixel = uint2(floor(IN.hpos.xy));
    uint tileX = pixel.x >> 5;
    uint tileY = pixel.y >> 5;
    int3 cell = int3(pixel.x - (tileX << 5), pixel.y - (tileY << 5), (tileY << 3) + tileX);
    if (any(cell < 0) || any(cell >= 32))
    {
        return 0.0;
    }

    float cellSize = max(giCellSize, 0.05);
    float3 gridOrigin = floor(eyePosWorld / cellSize) * cellSize
        + float3(-16.0, -16.0, -8.0) * cellSize;
    float3 worldPosition = gridOrigin + (float3(cell) + 0.5) * cellSize;
    float shellThickness = cellSize * 0.72;

    int boxCount = (int)clamp(geometryBoxCount, 0.0, 16.0);
    [loop]
    for (int boxIndex = 0; boxIndex < 16; ++boxIndex)
    {
        if (boxIndex >= boxCount)
        {
            break;
        }
        if (beamrtVoxelBoxSurface(worldPosition, shellThickness, boxIndex))
        {
            return float4(0.10, 0.75, 0.18, 1.0);
        }
    }

    int activeSurfelCount = (int)clamp(surfelCount, 0.0, 32.0);
    [loop]
    for (int surfelIndex = 0; surfelIndex < 32; ++surfelIndex)
    {
        if (surfelIndex >= activeSurfelCount)
        {
            break;
        }
        if (beamrtVoxelSurfelSurface(worldPosition, shellThickness, surfelIndex))
        {
            return float4(0.08, 0.35, 1.0, 1.0);
        }
    }

    return 0.0;
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
