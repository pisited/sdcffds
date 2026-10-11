#include "shaders/common/postFx/postFx.h.hlsl"

uniform_sampler2D(voxelAtlasTex, 0);
uniform_sampler2D(backBufferTex, 1);

cbuffer perDraw : register(b0)
{
    uniform float3 eyePosWorld;
    uniform float voxelCellSize;
    uniform float voxelDebugMode;
    uniform float voxelMaxSteps;
    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

float4 beamrtLoadVoxel(int3 cell)
{
    if (any(cell < 0) || any(cell >= 32))
    {
        return 0.0;
    }
    uint voxelZ = (uint)cell.z;
    uint tileX = voxelZ & 7u;
    uint tileY = voxelZ >> 3;
    float2 atlasPixel = float2(tileX * 32 + cell.x, tileY * 32 + cell.y) + 0.5;
    return tex2Dlod(voxelAtlasTex, float4(atlasPixel / float2(256.0, 128.0), 0.0, 0.0));
}

float3 beamrtSafeInverse(float3 value)
{
    float3 signValue = float3(value.x < 0.0 ? -1.0 : 1.0,
                              value.y < 0.0 ? -1.0 : 1.0,
                              value.z < 0.0 ? -1.0 : 1.0);
    return signValue / max(abs(value), 0.000001);
}

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    float cellSize = max(voxelCellSize, 0.05);
    float3 rayDirection = normalize(IN.wsEyeRay);
    float3 gridOrigin = floor(eyePosWorld / cellSize) * cellSize
        + float3(-16.0, -16.0, -8.0) * cellSize;
    float3 gridMaximum = gridOrigin + 32.0 * cellSize;
    float3 inverseDirection = beamrtSafeInverse(rayDirection);
    float3 t0 = (gridOrigin - eyePosWorld) * inverseDirection;
    float3 t1 = (gridMaximum - eyePosWorld) * inverseDirection;
    float3 tMin3 = min(t0, t1);
    float3 tMax3 = max(t0, t1);
    float tNear = max(max(tMin3.x, tMin3.y), tMin3.z);
    float tFar = min(min(tMax3.x, tMax3.y), tMax3.z);
    float4 background = tex2D(backBufferTex, IN.uv1);
    if (tFar < max(tNear, 0.0))
    {
        return background * 0.22;
    }

    float travel = max(tNear, 0.0) + cellSize * 0.0005;
    float3 startPosition = eyePosWorld + rayDirection * travel;
    int3 cell = clamp(int3(floor((startPosition - gridOrigin) / cellSize)), 0, 31);
    int3 stepDirection = int3(rayDirection.x >= 0.0 ? 1 : -1,
                              rayDirection.y >= 0.0 ? 1 : -1,
                              rayDirection.z >= 0.0 ? 1 : -1);
    float3 nextBoundary = gridOrigin + (float3(cell)
        + float3(stepDirection.x > 0 ? 1.0 : 0.0,
                 stepDirection.y > 0 ? 1.0 : 0.0,
                 stepDirection.z > 0 ? 1.0 : 0.0)) * cellSize;
    float3 tMax = (nextBoundary - eyePosWorld) * inverseDirection;
    float3 tDelta = abs(cellSize * inverseDirection);
    float3 hitNormal = -rayDirection;
    int executedSteps = 0;
    int maximumSteps = (int)clamp(floor(voxelMaxSteps + 0.5), 1.0, 128.0);

    [loop]
    for (int stepIndex = 0; stepIndex < 128; ++stepIndex)
    {
        if (stepIndex >= maximumSteps || any(cell < 0) || any(cell >= 32))
        {
            break;
        }
        executedSteps = stepIndex + 1;
        float4 voxel = beamrtLoadVoxel(cell);
        if (voxel.a > 0.5)
        {
            if (voxelDebugMode < 0.5)
            {
                return float4(0.05, 1.0, 0.12, 1.0);
            }
            if (voxelDebugMode < 1.5)
            {
                return float4(abs(hitNormal), 1.0);
            }
            if (voxelDebugMode < 2.5)
            {
                float heat = (float)executedSteps / max((float)maximumSteps, 1.0);
                return float4(saturate(float3(heat * 2.0, 1.0 - abs(heat * 2.0 - 1.0), 1.0 - heat)), 1.0);
            }
            return float4(frac(float3(cell) * float3(0.173, 0.317, 0.619)), 1.0);
        }

        if (tMax.x <= tMax.y && tMax.x <= tMax.z)
        {
            travel = tMax.x;
            tMax.x += tDelta.x;
            cell.x += stepDirection.x;
            hitNormal = float3(-(float)stepDirection.x, 0.0, 0.0);
        }
        else if (tMax.y <= tMax.z)
        {
            travel = tMax.y;
            tMax.y += tDelta.y;
            cell.y += stepDirection.y;
            hitNormal = float3(0.0, -(float)stepDirection.y, 0.0);
        }
        else
        {
            travel = tMax.z;
            tMax.z += tDelta.z;
            cell.z += stepDirection.z;
            hitNormal = float3(0.0, 0.0, -(float)stepDirection.z);
        }
        if (travel > tFar)
        {
            break;
        }
    }

    if (voxelDebugMode >= 1.5 && voxelDebugMode < 2.5)
    {
        float heat = (float)executedSteps / max((float)maximumSteps, 1.0);
        return float4(heat * 0.35, 0.0, 0.05, 1.0);
    }
    return background * 0.22;
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
