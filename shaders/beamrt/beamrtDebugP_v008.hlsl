#include "beamrtDebug.h.hlsl"

#ifdef SHADER_STAGE_VS
    #define mainV main
#else
    #define mainP main
#endif

// Project an eye-relative world vector back into the current PostFX UV field.
// processPostFxVert supplies an affine wsEyeRay across the fullscreen triangle.
// Solving eyeVector = depth * eyeRay(uv) gives both UV and the same normalized
// eye-linear depth used by decodeGBuffer, without requiring a private matrix.
bool beamrtProjectEyeVector(
    float3 eyeVector,
    float3 currentEyeRay,
    float3 eyeRayDu,
    float3 eyeRayDv,
    float2 currentUv,
    out float2 projectedUv,
    out float projectedDepth)
{
    float3 duCrossDv = cross(eyeRayDu, eyeRayDv);
    float determinant = dot(currentEyeRay, duCrossDv);
    if (abs(determinant) < 0.00000001)
    {
        projectedUv = 0.0;
        projectedDepth = 0.0;
        return false;
    }

    projectedDepth = dot(eyeVector, duCrossDv) / determinant;
    float weightedDu = dot(currentEyeRay, cross(eyeVector, eyeRayDv)) / determinant;
    float weightedDv = dot(currentEyeRay, cross(eyeRayDu, eyeVector)) / determinant;

    if (projectedDepth <= 0.000001)
    {
        projectedUv = 0.0;
        return false;
    }

    projectedUv = currentUv + float2(weightedDu, weightedDv) / projectedDepth;
    return true;
}

struct BeamRTRayHit
{
    float hit;
    float stepIndex;
    float travelDistance;
    float2 uv;
};

void beamrtGetGeometryBox(int index, out float3 boxMin, out float3 boxMax)
{
    boxMin = 0.0;
    boxMax = 0.0;
    if (index == 0) { boxMin = geometryBoxMin0.xyz; boxMax = geometryBoxMax0.xyz; }
    else if (index == 1) { boxMin = geometryBoxMin1.xyz; boxMax = geometryBoxMax1.xyz; }
    else if (index == 2) { boxMin = geometryBoxMin2.xyz; boxMax = geometryBoxMax2.xyz; }
    else if (index == 3) { boxMin = geometryBoxMin3.xyz; boxMax = geometryBoxMax3.xyz; }
    else if (index == 4) { boxMin = geometryBoxMin4.xyz; boxMax = geometryBoxMax4.xyz; }
    else if (index == 5) { boxMin = geometryBoxMin5.xyz; boxMax = geometryBoxMax5.xyz; }
    else if (index == 6) { boxMin = geometryBoxMin6.xyz; boxMax = geometryBoxMax6.xyz; }
    else if (index == 7) { boxMin = geometryBoxMin7.xyz; boxMax = geometryBoxMax7.xyz; }
    else if (index == 8) { boxMin = geometryBoxMin8.xyz; boxMax = geometryBoxMax8.xyz; }
    else if (index == 9) { boxMin = geometryBoxMin9.xyz; boxMax = geometryBoxMax9.xyz; }
    else if (index == 10) { boxMin = geometryBoxMin10.xyz; boxMax = geometryBoxMax10.xyz; }
    else if (index == 11) { boxMin = geometryBoxMin11.xyz; boxMax = geometryBoxMax11.xyz; }
    else if (index == 12) { boxMin = geometryBoxMin12.xyz; boxMax = geometryBoxMax12.xyz; }
    else if (index == 13) { boxMin = geometryBoxMin13.xyz; boxMax = geometryBoxMax13.xyz; }
    else if (index == 14) { boxMin = geometryBoxMin14.xyz; boxMax = geometryBoxMax14.xyz; }
    else if (index == 15) { boxMin = geometryBoxMin15.xyz; boxMax = geometryBoxMax15.xyz; }
}

void beamrtGetOrientedGeometryBox(
    int index,
    out float3 center,
    out float3 halfExtents,
    out float3 axisX,
    out float3 axisY,
    out float3 axisZ)
{
    float4 centerHalfX = 0.0;
    float4 axisXHalfY = 0.0;
    float4 axisYHalfZ = 0.0;
    if (index == 0) { centerHalfX = geometryObbCenterHalfX0; axisXHalfY = geometryObbAxisXHalfY0; axisYHalfZ = geometryObbAxisYHalfZ0; }
    else if (index == 1) { centerHalfX = geometryObbCenterHalfX1; axisXHalfY = geometryObbAxisXHalfY1; axisYHalfZ = geometryObbAxisYHalfZ1; }
    else if (index == 2) { centerHalfX = geometryObbCenterHalfX2; axisXHalfY = geometryObbAxisXHalfY2; axisYHalfZ = geometryObbAxisYHalfZ2; }
    else if (index == 3) { centerHalfX = geometryObbCenterHalfX3; axisXHalfY = geometryObbAxisXHalfY3; axisYHalfZ = geometryObbAxisYHalfZ3; }
    else if (index == 4) { centerHalfX = geometryObbCenterHalfX4; axisXHalfY = geometryObbAxisXHalfY4; axisYHalfZ = geometryObbAxisYHalfZ4; }
    else if (index == 5) { centerHalfX = geometryObbCenterHalfX5; axisXHalfY = geometryObbAxisXHalfY5; axisYHalfZ = geometryObbAxisYHalfZ5; }
    else if (index == 6) { centerHalfX = geometryObbCenterHalfX6; axisXHalfY = geometryObbAxisXHalfY6; axisYHalfZ = geometryObbAxisYHalfZ6; }
    else if (index == 7) { centerHalfX = geometryObbCenterHalfX7; axisXHalfY = geometryObbAxisXHalfY7; axisYHalfZ = geometryObbAxisYHalfZ7; }
    else if (index == 8) { centerHalfX = geometryObbCenterHalfX8; axisXHalfY = geometryObbAxisXHalfY8; axisYHalfZ = geometryObbAxisYHalfZ8; }
    else if (index == 9) { centerHalfX = geometryObbCenterHalfX9; axisXHalfY = geometryObbAxisXHalfY9; axisYHalfZ = geometryObbAxisYHalfZ9; }
    else if (index == 10) { centerHalfX = geometryObbCenterHalfX10; axisXHalfY = geometryObbAxisXHalfY10; axisYHalfZ = geometryObbAxisYHalfZ10; }
    else if (index == 11) { centerHalfX = geometryObbCenterHalfX11; axisXHalfY = geometryObbAxisXHalfY11; axisYHalfZ = geometryObbAxisYHalfZ11; }
    else if (index == 12) { centerHalfX = geometryObbCenterHalfX12; axisXHalfY = geometryObbAxisXHalfY12; axisYHalfZ = geometryObbAxisYHalfZ12; }
    else if (index == 13) { centerHalfX = geometryObbCenterHalfX13; axisXHalfY = geometryObbAxisXHalfY13; axisYHalfZ = geometryObbAxisYHalfZ13; }
    else if (index == 14) { centerHalfX = geometryObbCenterHalfX14; axisXHalfY = geometryObbAxisXHalfY14; axisYHalfZ = geometryObbAxisYHalfZ14; }
    else if (index == 15) { centerHalfX = geometryObbCenterHalfX15; axisXHalfY = geometryObbAxisXHalfY15; axisYHalfZ = geometryObbAxisYHalfZ15; }

    center = centerHalfX.xyz;
    halfExtents = float3(centerHalfX.w, axisXHalfY.w, axisYHalfZ.w);
    axisX = normalize(axisXHalfY.xyz);
    axisY = normalize(axisYHalfZ.xyz);
    axisZ = normalize(cross(axisX, axisY));
}

void beamrtGetSurfel(int index, out float3 position, out float radius, out float3 normal, out float sourceId)
{
    float4 positionRadius = 0.0;
    float4 normalSource = float4(0.0, 0.0, 1.0, 0.0);
    if (index == 0) { positionRadius = surfelPositionRadius0; normalSource = surfelNormalSource0; }
    else if (index == 1) { positionRadius = surfelPositionRadius1; normalSource = surfelNormalSource1; }
    else if (index == 2) { positionRadius = surfelPositionRadius2; normalSource = surfelNormalSource2; }
    else if (index == 3) { positionRadius = surfelPositionRadius3; normalSource = surfelNormalSource3; }
    else if (index == 4) { positionRadius = surfelPositionRadius4; normalSource = surfelNormalSource4; }
    else if (index == 5) { positionRadius = surfelPositionRadius5; normalSource = surfelNormalSource5; }
    else if (index == 6) { positionRadius = surfelPositionRadius6; normalSource = surfelNormalSource6; }
    else if (index == 7) { positionRadius = surfelPositionRadius7; normalSource = surfelNormalSource7; }
    else if (index == 8) { positionRadius = surfelPositionRadius8; normalSource = surfelNormalSource8; }
    else if (index == 9) { positionRadius = surfelPositionRadius9; normalSource = surfelNormalSource9; }
    else if (index == 10) { positionRadius = surfelPositionRadius10; normalSource = surfelNormalSource10; }
    else if (index == 11) { positionRadius = surfelPositionRadius11; normalSource = surfelNormalSource11; }
    else if (index == 12) { positionRadius = surfelPositionRadius12; normalSource = surfelNormalSource12; }
    else if (index == 13) { positionRadius = surfelPositionRadius13; normalSource = surfelNormalSource13; }
    else if (index == 14) { positionRadius = surfelPositionRadius14; normalSource = surfelNormalSource14; }
    else if (index == 15) { positionRadius = surfelPositionRadius15; normalSource = surfelNormalSource15; }
    else if (index == 16) { positionRadius = surfelPositionRadius16; normalSource = surfelNormalSource16; }
    else if (index == 17) { positionRadius = surfelPositionRadius17; normalSource = surfelNormalSource17; }
    else if (index == 18) { positionRadius = surfelPositionRadius18; normalSource = surfelNormalSource18; }
    else if (index == 19) { positionRadius = surfelPositionRadius19; normalSource = surfelNormalSource19; }
    else if (index == 20) { positionRadius = surfelPositionRadius20; normalSource = surfelNormalSource20; }
    else if (index == 21) { positionRadius = surfelPositionRadius21; normalSource = surfelNormalSource21; }
    else if (index == 22) { positionRadius = surfelPositionRadius22; normalSource = surfelNormalSource22; }
    else if (index == 23) { positionRadius = surfelPositionRadius23; normalSource = surfelNormalSource23; }
    else if (index == 24) { positionRadius = surfelPositionRadius24; normalSource = surfelNormalSource24; }
    else if (index == 25) { positionRadius = surfelPositionRadius25; normalSource = surfelNormalSource25; }
    else if (index == 26) { positionRadius = surfelPositionRadius26; normalSource = surfelNormalSource26; }
    else if (index == 27) { positionRadius = surfelPositionRadius27; normalSource = surfelNormalSource27; }
    else if (index == 28) { positionRadius = surfelPositionRadius28; normalSource = surfelNormalSource28; }
    else if (index == 29) { positionRadius = surfelPositionRadius29; normalSource = surfelNormalSource29; }
    else if (index == 30) { positionRadius = surfelPositionRadius30; normalSource = surfelNormalSource30; }
    else if (index == 31) { positionRadius = surfelPositionRadius31; normalSource = surfelNormalSource31; }
    position = positionRadius.xyz;
    radius = positionRadius.w;
    normal = normalize(normalSource.xyz);
    sourceId = normalSource.w;
}

bool beamrtRayBox(float3 origin, float3 direction, float3 boxMin, float3 boxMax, out float hitDistance)
{
    // Avoid using the receiver's own coarse proxy as an immediate false hit.
    float3 insideMargin = min(origin - boxMin, boxMax - origin);
    if (min(min(insideMargin.x, insideMargin.y), insideMargin.z) >= -0.001)
    {
        hitDistance = 0.0;
        return false;
    }

    float3 safeDirection = direction;
    safeDirection = float3(
        abs(safeDirection.x) < 0.000001 ? (safeDirection.x < 0.0 ? -0.000001 : 0.000001) : safeDirection.x,
        abs(safeDirection.y) < 0.000001 ? (safeDirection.y < 0.0 ? -0.000001 : 0.000001) : safeDirection.y,
        abs(safeDirection.z) < 0.000001 ? (safeDirection.z < 0.0 ? -0.000001 : 0.000001) : safeDirection.z
    );
    float3 inverseDirection = 1.0 / safeDirection;
    float3 t0 = (boxMin - origin) * inverseDirection;
    float3 t1 = (boxMax - origin) * inverseDirection;
    float3 tNear3 = min(t0, t1);
    float3 tFar3 = max(t0, t1);
    float tNear = max(max(tNear3.x, tNear3.y), tNear3.z);
    float tFar = min(min(tFar3.x, tFar3.y), tFar3.z);
    hitDistance = max(tNear, 0.0);
    return tFar >= hitDistance && hitDistance > 0.001;
}

bool beamrtTraceGeometryProxies(float3 origin, float3 direction, out float nearestDistance, out float proxyIndex)
{
    nearestDistance = max(geometryMaxDistance, 0.001);
    proxyIndex = -1.0;
    int count = (int)clamp(geometryBoxCount, 0.0, 16.0);

    [loop]
    for (int index = 0; index < 16; ++index)
    {
        if (index >= count)
        {
            break;
        }

        float3 boxMin;
        float3 boxMax;
        beamrtGetGeometryBox(index, boxMin, boxMax);
        float candidateDistance;
        if (beamrtRayBox(origin, direction, boxMin, boxMax, candidateDistance) && candidateDistance < nearestDistance)
        {
            nearestDistance = candidateDistance;
            proxyIndex = (float)index;
        }
    }

    return proxyIndex >= 0.0;
}

bool beamrtTraceOrientedGeometryProxies(float3 origin, float3 direction, out float nearestDistance, out float proxyIndex)
{
    nearestDistance = max(geometryMaxDistance, 0.001);
    proxyIndex = -1.0;
    int count = (int)clamp(geometryBoxCount, 0.0, 16.0);

    [loop]
    for (int index = 0; index < 16; ++index)
    {
        if (index >= count)
        {
            break;
        }

        float3 center;
        float3 halfExtents;
        float3 axisX;
        float3 axisY;
        float3 axisZ;
        beamrtGetOrientedGeometryBox(index, center, halfExtents, axisX, axisY, axisZ);
        float3 offset = origin - center;
        float3 localOrigin = float3(dot(offset, axisX), dot(offset, axisY), dot(offset, axisZ));
        float3 localDirection = float3(dot(direction, axisX), dot(direction, axisY), dot(direction, axisZ));
        float candidateDistance;
        if (beamrtRayBox(localOrigin, localDirection, -halfExtents, halfExtents, candidateDistance)
            && candidateDistance < nearestDistance)
        {
            nearestDistance = candidateDistance;
            proxyIndex = (float)index;
        }
    }

    return proxyIndex >= 0.0;
}

bool beamrtTraceSurfels(
    float3 origin,
    float3 direction,
    out float nearestDistance,
    out float surfelIndex,
    out float3 hitNormal,
    out float sourceId)
{
    nearestDistance = max(surfelMaxDistance, 0.001);
    surfelIndex = -1.0;
    hitNormal = float3(0.0, 0.0, 1.0);
    sourceId = 0.0;
    int count = (int)clamp(surfelCount, 0.0, 32.0);

    [loop]
    for (int index = 0; index < 32; ++index)
    {
        if (index >= count)
        {
            break;
        }

        float3 position;
        float radius;
        float3 normal;
        float candidateSource;
        beamrtGetSurfel(index, position, radius, normal, candidateSource);
        float denominator = dot(direction, normal);
        if (abs(denominator) < 0.0001)
        {
            continue;
        }
        float candidateDistance = dot(position - origin, normal) / denominator;
        if (candidateDistance <= 0.01 || candidateDistance >= nearestDistance)
        {
            continue;
        }
        float3 candidatePoint = origin + direction * candidateDistance;
        float3 radialOffset = candidatePoint - position;
        radialOffset -= normal * dot(radialOffset, normal);
        if (dot(radialOffset, radialOffset) <= radius * radius)
        {
            nearestDistance = candidateDistance;
            surfelIndex = (float)index;
            hitNormal = normal;
            sourceId = candidateSource;
        }
    }

    return surfelIndex >= 0.0;
}

BeamRTRayHit beamrtTraceRay(
    float3 rayOrigin,
    float3 rayDirection,
    float3 currentEyeRay,
    float3 eyeRayDu,
    float3 eyeRayDv,
    float2 currentUv)
{
    BeamRTRayHit result;
    result.hit = 0.0;
    result.stepIndex = -1.0;
    result.travelDistance = 0.0;
    result.uv = 0.0;

    float2 viewportOtherCorner = rtParams0.xy + rtParams0.zw;
    float2 viewportMin = min(rtParams0.xy, viewportOtherCorner);
    float2 viewportMax = max(rtParams0.xy, viewportOtherCorner);
    float safeStepSize = max(rayStepSize, 0.0001);
    float safeThickness = max(rayThickness, 0.0001);
    float clampedMaxSteps = clamp(rayMaxSteps, 1.0, 64.0);

    [loop]
    for (int stepIndex = 0; stepIndex < 64; ++stepIndex)
    {
        if ((float)stepIndex >= clampedMaxSteps)
        {
            break;
        }

        float travelDistance = ((float)stepIndex + 1.0) * safeStepSize;
        float3 rayPoint = rayOrigin + rayDirection * travelDistance;
        float2 rayUv;
        float rayEyeDepth;
        bool projected = beamrtProjectEyeVector(
            rayPoint - eyePosWorld,
            currentEyeRay,
            eyeRayDu,
            eyeRayDv,
            currentUv,
            rayUv,
            rayEyeDepth
        );

        if (!projected || rayEyeDepth >= 0.9999 || any(rayUv <= viewportMin) || any(rayUv >= viewportMax))
        {
            break;
        }

        float sceneNdcDepth = tex2Dlod(prepassDepthTex, float4(rayUv, 0.0, 0.0)).r;
        float sceneRealDepth = ndcToRealDepth(sceneNdcDepth, projParams.zw);
        float sceneEyeDepth = realToEyeLinearDepth(sceneRealDepth, projParams);
        if (sceneEyeDepth >= 0.9999)
        {
            continue;
        }

        // Convert normalized eye-depth separation back to world units so the
        // acceptance thickness remains stable across different far planes.
        float depthDeltaWorld = (rayEyeDepth - sceneEyeDepth) * projParams.y;
        if (depthDeltaWorld >= 0.0 && depthDeltaWorld <= safeThickness)
        {
            result.hit = 1.0;
            result.stepIndex = (float)stepIndex;
            result.travelDistance = travelDistance;
            result.uv = rayUv;
            break;
        }
    }

    return result;
}

float beamrtHash13(float3 value)
{
    value = frac(value * 0.1031);
    value += dot(value, value.yzx + 33.33);
    return frac((value.x + value.y) * value.z);
}

float3 beamrtDiffuseDirection(float3 worldPosition, float3 normal)
{
    // Quantization keeps the one-sample pattern anchored to 0.25-world-unit
    // cells instead of to screen pixels while Phase 4 history is unavailable.
    float3 cell = floor(worldPosition * 4.0);
    float u1 = beamrtHash13(cell + float3(0.0, 17.0, 31.0));
    float u2 = beamrtHash13(cell + float3(47.0, 11.0, 5.0));
    float radius = sqrt(u1);
    float sinePhi;
    float cosinePhi;
    sincos(u2 * 6.28318530718, sinePhi, cosinePhi);

    float3 helperAxis = abs(normal.z) < 0.999 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
    float3 tangent = normalize(cross(helperAxis, normal));
    float3 bitangent = cross(normal, tangent);
    float3 localDirection = float3(radius * cosinePhi, radius * sinePhi, sqrt(max(0.0, 1.0 - u1)));
    return normalize(tangent * localDirection.x + bitangent * localDirection.y + normal * localDirection.z);
}

float2 beamrtPrepassUvToBackbufferUv(float2 prepassUv)
{
    float2 viewportUv = (prepassUv - rtParams0.xy) / rtParams0.zw;
    return viewportCoordToRenderTarget(viewportUv, rtParams2);
}

float beamrtScreenEdgeConfidence(float2 prepassUv)
{
    float2 viewportOtherCorner = rtParams0.xy + rtParams0.zw;
    float2 viewportMin = min(rtParams0.xy, viewportOtherCorner);
    float2 viewportMax = max(rtParams0.xy, viewportOtherCorner);
    float2 normalizedUv = (prepassUv - viewportMin) / max(viewportMax - viewportMin, 0.000001);
    float edgeDistance = min(min(normalizedUv.x, normalizedUv.y), min(1.0 - normalizedUv.x, 1.0 - normalizedUv.y));
    return saturate(edgeDistance / 0.08);
}

float4 mainP(PFXVertToPix IN) : SV_Target0
{
    // Mode 0: leave the rendered scene unchanged.
    if (debugMode < 0.5)
    {
        return tex2D(backBufferTex, IN.uv2);
    }

    // BeamNG's packed Advanced Lighting prepass:
    // RG = octahedral world normal, B = roughness.
    float4 packedPrepass = tex2D(prepassTex, IN.uv0);

    // The shipped helper returns world normal in XYZ and eye-linear depth in W.
    float4 decoded = decodeGBuffer(
        TEX_SAMPLER(prepassDepthTex),
        TEX_SAMPLER(prepassTex),
        IN.uv0,
        projParams
    );

    // Mode 1: decoded world-space normal.
    if (debugMode < 1.5)
    {
        return float4(decoded.xyz * 0.5 + 0.5, 1.0);
    }

    // Mode 2: eye-linear depth, scaled only for display.
    if (debugMode < 2.5)
    {
        float displayedDepth = saturate(decoded.w * max(depthGain, 0.0));
        return float4(displayedDepth.xxx, 1.0);
    }

    // Mode 3: roughness from #prepass[RT0].b.
    if (debugMode < 3.5)
    {
        float roughness = packedPrepass.b;
        return float4(roughness.xxx, 1.0);
    }

    // Modes 4 through 10 begin with reconstructed world position. BeamNG's shipped caustics and fog
    // shaders use this exact eyePosWorld + wsEyeRay * eye-linear-depth path.
    if (decoded.w >= 0.9999)
    {
        if (debugMode >= 5.5 && debugMode < 6.5)
        {
            return tex2D(backBufferTex, IN.uv2);
        }
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    float3 worldPosition = eyePosWorld + IN.wsEyeRay * decoded.w;

    // Mode 4: repeating RGB ramps make camera-relative errors visible as swimming.
    if (debugMode < 4.5)
    {
        float3 positionColor = frac(worldPosition * max(positionScale, 0.000001));
        return float4(positionColor, 1.0);
    }

    // Modes 5 through 10 share the accepted screen-space depth tracer.
    // BeamNG's LIDAR DDA also detects a hit when a projected ray crosses scene
    // depth. This generic PostEffect derives projection from wsEyeRay instead
    // of relying on the compute-only LIDAR matrix setup.
    float uvDx = ddx(IN.uv0.x);
    float uvDy = ddy(IN.uv0.y);
    if (abs(uvDx) < 0.00000001 || abs(uvDy) < 0.00000001)
    {
        if (debugMode >= 5.5 && debugMode < 6.5)
        {
            return tex2D(backBufferTex, IN.uv2);
        }
        return float4(1.0, 0.0, 1.0, 1.0);
    }

    float3 eyeRayDu = ddx(IN.wsEyeRay) / uvDx;
    float3 eyeRayDv = ddy(IN.wsEyeRay) / uvDy;
    float3 rayOrigin = worldPosition + decoded.xyz * max(rayNormalBias, 0.0);
    float clampedMaxSteps = clamp(rayMaxSteps, 1.0, 64.0);

    // Mode 5: deterministic screen-space reflection-ray hit diagnostic.
    if (debugMode < 5.5)
    {
        float3 incidentDirection = normalize(worldPosition - eyePosWorld);
        float3 reflectedDirection = normalize(reflect(incidentDirection, decoded.xyz));
        BeamRTRayHit reflectionHit = beamrtTraceRay(
            rayOrigin,
            reflectedDirection,
            IN.wsEyeRay,
            eyeRayDu,
            eyeRayDv,
            IN.uv0
        );

        if (reflectionHit.hit < 0.5)
        {
            return float4(0.03, 0.0, 0.10, 1.0);
        }

        // Cyan means an early hit and yellow means a late hit.
        float hitFraction = saturate((reflectionHit.stepIndex + 1.0) / clampedMaxSteps);
        float3 hitColor = lerp(float3(0.0, 1.0, 1.0), float3(1.0, 1.0, 0.0), hitFraction);
        return float4(hitColor, 1.0);
    }

    // Modes 7 and 8 compare the visible-depth tracer with GELUA-uploaded static
    // scene-object bounds. Mode 7 retains the accepted AABB baseline. Mode 8
    // uses oriented local mesh boxes and additionally paints AABB-only hits
    // orange, exposing the coarse corner volume behind the square-ish result.
    if (debugMode >= 6.5 && debugMode < 8.5)
    {
        float3 incidentDirection = normalize(worldPosition - eyePosWorld);
        float3 reflectedDirection = normalize(reflect(incidentDirection, decoded.xyz));
        BeamRTRayHit screenHit = beamrtTraceRay(
            rayOrigin,
            reflectedDirection,
            IN.wsEyeRay,
            eyeRayDu,
            eyeRayDv,
            IN.uv0
        );
        float aabbDistance;
        float aabbIndex;
        bool aabbHit = beamrtTraceGeometryProxies(rayOrigin, reflectedDirection, aabbDistance, aabbIndex);
        bool depthHit = screenHit.hit >= 0.5;

        // Mode 7 legend: cyan screen-only, magenta AABB-only, white both.
        if (debugMode < 7.5)
        {
            if (depthHit && aabbHit)
            {
                return float4(1.0, 1.0, 1.0, 1.0);
            }
            if (aabbHit)
            {
                float distanceFade = saturate(1.0 - aabbDistance / max(geometryMaxDistance, 0.001));
                return float4(0.35 + 0.65 * distanceFade, 0.0, 1.0, 1.0);
            }
            if (depthHit)
            {
                return float4(0.0, 1.0, 1.0, 1.0);
            }
            return float4(0.03, 0.0, 0.10, 1.0);
        }

        // Mode 8 legend: cyan screen-only, magenta OBB-only, white screen+OBB,
        // orange AABB-only excess, and dark purple a complete miss.
        float obbDistance;
        float obbIndex;
        bool obbHit = beamrtTraceOrientedGeometryProxies(
            rayOrigin,
            reflectedDirection,
            obbDistance,
            obbIndex
        );
        if (depthHit && obbHit)
        {
            return float4(1.0, 1.0, 1.0, 1.0);
        }
        if (obbHit)
        {
            float distanceFade = saturate(1.0 - obbDistance / max(geometryMaxDistance, 0.001));
            return float4(0.35 + 0.65 * distanceFade, 0.0, 1.0, 1.0);
        }
        if (aabbHit)
        {
            return float4(1.0, 0.35, 0.0, 1.0);
        }
        if (depthHit)
        {
            return float4(0.0, 1.0, 1.0, 1.0);
        }
        return float4(0.03, 0.0, 0.10, 1.0);
    }

    // Modes 9 and 10 trace against sparse world-space surfel discs generated
    // by GELUA's detailed Engine.castRay render-geometry query. Unlike boxes,
    // each sample carries a real hit position and surface normal.
    if (debugMode >= 8.5)
    {
        float3 incidentDirection = normalize(worldPosition - eyePosWorld);
        float3 reflectedDirection = normalize(reflect(incidentDirection, decoded.xyz));
        float surfelDistance;
        float surfelIndex;
        float3 surfelNormal;
        float surfelSource;
        bool surfelHit = beamrtTraceSurfels(
            rayOrigin,
            reflectedDirection,
            surfelDistance,
            surfelIndex,
            surfelNormal,
            surfelSource
        );

        // Mode 9: display the true detailed-raycast normal at the nearest
        // intersected surfel. Misses remain dark purple.
        if (debugMode < 9.5)
        {
            if (!surfelHit)
            {
                return float4(0.03, 0.0, 0.10, 1.0);
            }
            float distanceConfidence = saturate(1.0 - surfelDistance / max(surfelMaxDistance, 0.001));
            float3 normalColor = surfelNormal * 0.5 + 0.5;
            return float4(normalColor * lerp(0.45, 1.0, distanceConfidence), 1.0);
        }

        // Mode 10: cyan is visible-depth only, green is surfel only, white is
        // both, and dark purple is a miss. A green region proves that a ray
        // reached detailed world geometry absent from the current depth view.
        BeamRTRayHit screenHit = beamrtTraceRay(
            rayOrigin,
            reflectedDirection,
            IN.wsEyeRay,
            eyeRayDu,
            eyeRayDv,
            IN.uv0
        );
        bool depthHit = screenHit.hit >= 0.5;
        if (depthHit && surfelHit)
        {
            return float4(1.0, 1.0, 1.0, 1.0);
        }
        if (surfelHit)
        {
            return surfelSource > 0.5
                ? float4(0.35, 1.0, 0.0, 1.0)
                : float4(0.0, 1.0, 0.25, 1.0);
        }
        if (depthHit)
        {
            return float4(0.0, 1.0, 1.0, 1.0);
        }
        return float4(0.03, 0.0, 0.10, 1.0);
    }

    // Mode 6: one deterministic cosine-weighted diffuse bounce. This uses
    // BeamNG's shipped HDR decode/encode convention and adds only color from a
    // visible screen-space hit; misses preserve the original scene.
    float4 baseEncoded = tex2D(backBufferTex, IN.uv2);
    if (giStrength <= 0.0)
    {
        return baseEncoded;
    }

    float3 diffuseDirection = beamrtDiffuseDirection(worldPosition, decoded.xyz);
    BeamRTRayHit diffuseHit = beamrtTraceRay(
        rayOrigin,
        diffuseDirection,
        IN.wsEyeRay,
        eyeRayDu,
        eyeRayDv,
        IN.uv0
    );

    if (diffuseHit.hit < 0.5)
    {
        return baseEncoded;
    }

    float2 hitBackbufferUv = beamrtPrepassUvToBackbufferUv(diffuseHit.uv);
    float3 baseLinear = hdrDecode(baseEncoded.rgb);
    float3 bounceLinear = hdrDecode(tex2D(backBufferTex, hitBackbufferUv).rgb);
    float bouncePeak = max(max(bounceLinear.r, bounceLinear.g), bounceLinear.b);
    bounceLinear *= min(1.0, max(giClamp, 0.0001) / max(bouncePeak, 0.0001));

    float3 hitNormal = decodeNormalXY(tex2D(prepassTex, diffuseHit.uv).xy);
    float receiverCosine = saturate(dot(decoded.xyz, diffuseDirection));
    float emitterCosine = saturate(dot(hitNormal, -diffuseDirection));
    float edgeConfidence = beamrtScreenEdgeConfidence(diffuseHit.uv);
    float distanceConfidence = saturate(1.0 - diffuseHit.stepIndex / clampedMaxSteps);
    float roughSurfaceWeight = lerp(0.35, 1.0, saturate(packedPrepass.b));
    float bounceWeight = receiverCosine * emitterCosine * edgeConfidence * distanceConfidence * roughSurfaceWeight;
    float3 composedLinear = baseLinear + bounceLinear * (max(giStrength, 0.0) * bounceWeight);
    return float4(hdrEncode(composedLinear), baseEncoded.a);
}

PFXVertToPix mainV(PFXVert IN)
{
    return processPostFxVert(IN);
}
