#include "shaders/common/postFx/postFx.h.hlsl"

cbuffer perDraw : register(b0)
{
    POSTFX_UNIFORMS
};

#include "shaders/common/postFx/postFx.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

// Temporary 32^3 research volume packed into a 256x128 2D target. Eight
// slices run across each row and four rows hold all 32 Z slices.
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

    bool floorVoxel = cell.z <= 2;
    bool backWall = cell.y >= 28 && cell.z <= 20;
    bool leftWall = cell.x <= 2 && cell.y >= 8 && cell.z <= 18;
    bool redBlock = all(cell >= int3(7, 17, 3)) && all(cell <= int3(12, 22, 10));
    bool blueBlock = all(cell >= int3(20, 20, 3)) && all(cell <= int3(25, 25, 15));
    bool emissiveBar = all(cell >= int3(11, 26, 15)) && all(cell <= int3(21, 27, 17));

    // Phase one is deliberately occupancy-only. The named shapes merely make
    // the DDA result easy to recognize; no material or radiance is stored.
    float occupied = (floorVoxel || backWall || leftWall || redBlock || blueBlock || emissiveBar)
        ? 1.0 : 0.0;
    return float4(0.0, 0.0, 0.0, occupied);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
