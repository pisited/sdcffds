#ifndef BEAMRT_COH_SSR_COMPOSITE_HLSL
#define BEAMRT_COH_SSR_COMPOSITE_HLSL

float4 CheapResolveSSR(float2 uv, float4 projectionParams, float4 centerSSR,
                       float centerRealDepth, float3 centerNormal, float roughness,
                       float surfaceMask, float centerPuddleMask, float centerWaterMask)
{
    if (uStochasticSSR > 0.5 && uStochasticReuse > 0.0001 && uTemporalStrength > 0.0001)
        return centerSSR;
    if (uResolveMode < 0.5)
        return centerSSR;

    float eligible = saturate(surfaceMask);
    if (centerSSR.a <= 0.0001)
        return centerSSR;

    float roughResolve = smoothstep(0.40, 0.90, roughness) * saturate(centerSSR.a * 2.0);

    float lineRepair = (1.0 - smoothstep(0.055, 0.24, roughness)) * saturate(max(centerSSR.a, eligible * 0.35) * 1.35);

    float resolveNeed = max(roughResolve, lineRepair * 0.82);

    if (resolveNeed <= 0.02)
        return centerSSR;

    float2 texelSize = 1.0 / max(gAuxSize, float2(1.0, 1.0));
    float radius = max(uResolveRadius, 0.5);
    float2 offsets[8] = {
        float2(0, -1),
        float2(0, 1),
        float2(-1, 0),
        float2(1, 0),
        float2(0, -2),
        float2(0, 2),
        float2(-2, 0),
        float2(2, 0)
    };
    bool wideResolve = centerSSR.a < 0.55 || roughResolve > 0.72;
    int resolveTapCount = wideResolve ? 8 : 4;

    float centerWeight = max(centerSSR.a, 0.2) * 2.0;
    float4 accum = centerSSR * centerWeight;
    float totalWeight = centerWeight;
    float centerLuma = BrtcLuma(centerSSR.rgb);
    float neighborLumaSum = 0.0;
    float neighborLumaMax = 0.0;
    float neighborCount = 0.0;

    [loop]
    for (int i = 0; i < 8; i++)
    {
        if (i >= resolveTapCount)
            break;
        float ring = (i < 4) ? 1.0 : 1.55;
        float2 sampleUV = clamp(uv + offsets[i] * texelSize * radius * ring, BEAMRT_COH_UV_CLAMP_LO, BEAMRT_COH_UV_CLAMP_HI);
        float4 sampleSSR = tex2Dlod(auxTex, float4(sampleUV, 0.0, 0.0));
        if (sampleSSR.a <= 0.0001)
            continue;

        float4 sampleCombinedDepth = LoadDebugDataPoint(sampleUV);
        float sampleEyeDepth01 = saturate(sampleCombinedDepth.r);
        float sampleRealDepth = sampleEyeDepth01 * projectionParams.y;
        if (sampleEyeDepth01 <= 0.000001 || sampleEyeDepth01 >= 0.999999)
            continue;

        float sampleWaterMask = (uWaterSSR > 0.5)
            ? saturate(sampleCombinedDepth.b)
            : 0.0;

        if (abs(sampleWaterMask - saturate(centerWaterMask)) > 0.25)
            continue;

        float3 sampleNormal;
        if (sampleWaterMask > 0.5)
        {
            sampleNormal = float3(0.0, 0.0, 1.0);
        }
        else
        {
            float4 samplePrepass = LoadPrepass(sampleUV);
            sampleNormal = DecodePrepassNormal(samplePrepass);
            if (centerPuddleMask > 0.01)
            {
                sampleNormal = centerNormal;
            }
        }

        float depthWeight = exp(-abs(sampleRealDepth - centerRealDepth) / max(uResolveDepthSigma, 0.001));
        float normalWeight = pow(saturate(dot(centerNormal, sampleNormal) * 0.5 + 0.5), max(uResolveNormalPower, 0.0));
        float verticalBoost = (abs(offsets[i].y) > abs(offsets[i].x)) ? 1.20 : 1.0;
        float alphaWeight = saturate(sampleSSR.a * 1.25);
        float sampleLuma = BrtcLuma(sampleSSR.rgb);
        float fireflyWeight = BrtcFireflyWeight(sampleSSR.rgb, centerLuma);
        float weight = alphaWeight * depthWeight * normalWeight * verticalBoost *
                       fireflyWeight;

        neighborLumaSum += sampleLuma;
        neighborLumaMax = max(neighborLumaMax, sampleLuma);
        neighborCount += 1.0;

        accum += sampleSSR * weight;
        totalWeight += weight;
    }

    float4 resolved = accum / max(totalWeight, 0.0001);
    resolved.a = max(centerSSR.a, resolved.a * 0.94);

    float4 result = lerp(centerSSR, resolved, saturate(resolveNeed));

    if (uFireflySuppression > 0.0001 && neighborCount >= 2.0)
    {
        float fireflyReference = max(neighborLumaSum / neighborCount, neighborLumaMax * 0.5);
        result.rgb = BrtcClampFirefly(result.rgb, fireflyReference);
    }

    return result;
}

float BrtcSSRViewFogTransport(float3 receiverWorldPos, float validReceiver)
{
    if (uFogTransport <= 0.0001 || validReceiver < 0.5)
        return 1.0;

    float viewTransmittance = computeSceneFog(
        eyePosWorld, receiverWorldPos, fogData.x, fogData.z);
    return lerp(1.0, saturate(viewTransmittance),
                saturate(uFogTransport));
}

static const int BEAMRT_COH_REBUILD_COARSE = 8;
static const int BEAMRT_COH_REBUILD_BISECT = 4;

bool BrtcRebuildReflection(PFXVertToPix IN, float2 uv, float3 receiverPos, float3 reflectDir, float hitMetres,
                          out float3 rebuiltColor, out float2 rebuiltUV)
{
    rebuiltColor = float3(0.0, 0.0, 0.0);
    rebuiltUV = uv;
    bool ok = false;
    SSRProjectionBasis basis = BuildProjectionBasis(IN, uv, receiverPos);
    float tNear=hitMetres*0.25,tFar=hitMetres*2.5;
    float receiverZ=BrtcEyeDepth01(receiverPos,projParams);
    float rayZ=dot(reflectDir,uCameraForward)/max(projParams.y,1.0);
    if (rayZ< -1e-9) tFar=min(tFar,(receiverZ-1e-6)/(-rayZ));
    else if (rayZ>1e-9) tNear=max(tNear,(1e-6-receiverZ)/rayZ);
    if (tFar<=tNear) return false;
    float zA, zB, cA, cB;
    float2 uvA = ProjectWorldToUVFast(basis, receiverPos + reflectDir * tNear, zA, cA);
    float2 uvB = ProjectWorldToUVFast(basis, receiverPos + reflectDir * tFar, zB, cB);
    if (zA > 1e-6 && zB > 1e-6)
    {
        float izA = 1.0 / zA;
        float izB = 1.0 / zB;
        float clipLo=0.0,clipHi=1.0;
        float2 segment=uvB-uvA;
        [unroll] for (int axis=0;axis<2;axis++)
        {
            if (abs(segment[axis])<1e-8)
            {
                if (uvA[axis]<=0.00005 || uvA[axis]>=0.99995) return false;
            }
            else
            {
                float a=(0.00005-uvA[axis])/segment[axis];
                float b=(0.99995-uvA[axis])/segment[axis];
                clipLo=max(clipLo,min(a,b)); clipHi=min(clipHi,max(a,b));
            }
        }
        if (clipHi<=clipLo) return false;
        float sFront = -1.0;
        float sBehind = -1.0;
        float sceneDepth[BEAMRT_COH_REBUILD_COARSE];
        [unroll] for (int sampleIndex=0;sampleIndex<BEAMRT_COH_REBUILD_COARSE;sampleIndex++)
        {
            float s=lerp(clipLo,clipHi,(float)sampleIndex/(BEAMRT_COH_REBUILD_COARSE-1));
            sceneDepth[sampleIndex]=LoadDebugDataPoint(lerp(uvA,uvB,s)).r;
        }
        int firstBehind=BEAMRT_COH_REBUILD_COARSE;
        [unroll] for (int crossIndex=0;crossIndex<BEAMRT_COH_REBUILD_COARSE;crossIndex++)
        {
            float s=lerp(clipLo,clipHi,(float)crossIndex/(BEAMRT_COH_REBUILD_COARSE-1));
            float z=1.0/lerp(izA,izB,s);
            if (z>=sceneDepth[crossIndex]) firstBehind=min(firstBehind,crossIndex);
        }
        if (firstBehind>0 && firstBehind<BEAMRT_COH_REBUILD_COARSE)
        {
            sFront=lerp(clipLo,clipHi,(float)(firstBehind-1)/(BEAMRT_COH_REBUILD_COARSE-1));
            sBehind=lerp(clipLo,clipHi,(float)firstBehind/(BEAMRT_COH_REBUILD_COARSE-1));
        }
        if (sFront >= 0.0 && sBehind > sFront)
        {
            [unroll]
            for (int b = 0; b < BEAMRT_COH_REBUILD_BISECT; b++)
            {
                float s = 0.5 * (sFront + sBehind);
                float z = 1.0 / lerp(izA, izB, s);
                if (z >= LoadDebugDataPoint(lerp(uvA, uvB, s)).r)
                    sBehind = s;
                else
                    sFront = s;
            }
            float2 q = lerp(uvA, uvB, sBehind);
            float z = 1.0 / lerp(izA, izB, sBehind);
            float d = LoadDebugDataPoint(q).r;
            if (d < 0.999999 && abs(z - d) <= max(0.03 * z, 0.05 / max(projParams.y, 1.0)))
            {
                rebuiltColor = max(tex2Dlod(sourceTex, float4(q, 0.0, 0.0)).rgb, 0.0);
                rebuiltUV = q;
                ok = true;
            }
        }
    }
    return ok;
}

float4 BrtcPrepareNativeCurrent(PFXVertToPix IN, float2 uv, float4 depth, float3 normal,
    float rough, float3 du, float3 dv, out float hit, out float support)
{
    float2 size = gAuxSize;
    if (uReuseGuides > 0.5) size.x *= 0.5;
    float2 p = (uv - uTraceJitterUV) * size - 0.5;
    int2 base = (int2)floor(p);
    float2 f = frac(p);
    float3 position = IN.wsEyeRay * depth.r;
    float footprint = depth.r * max(length(du)/size.x,length(dv)/size.y);
    float tolerance=max(max(footprint*0.20,0.01),depth.r*projParams.y*0.001);
    float4 sum=0; support=0; hit=63; float best=-1;
    float4 depths[4], prepasses[4], signals[4];
    float2 guideUVs[4];
    [unroll] for (int prefetchIndex=0;prefetchIndex<4;prefetchIndex++)
    {
        int2 q=clamp(base+int2(prefetchIndex&1,prefetchIndex>>1),int2(0,0),(int2)size-1);
        guideUVs[prefetchIndex]=clamp((float2(q)+0.5)/size+uTraceJitterUV,BEAMRT_COH_UV_CLAMP_LO,BEAMRT_COH_UV_CLAMP_HI);
        depths[prefetchIndex]=LoadDebugDataPoint(guideUVs[prefetchIndex]);
        prepasses[prefetchIndex]=prepassTexTex.Load(BrtcTexelAt(guideUVs[prefetchIndex],gPrepassSize,gPrepassMaxCoord));
        signals[prefetchIndex]=auxTexTex.Load(int3(q,0));
    }
    [unroll] for (int i=0;i<4;i++)
    {
        int2 o=int2(i&1,i>>1), q=base+o;
        if (any(q<0) || any(q>=(int2)size)) continue;
        float2 quv=guideUVs[i];
        float4 d=depths[i];
        if (d.r<=1e-6 || d.r>=0.999999 || abs(d.b-depth.b)>0.25) continue;
        float4 pp=prepasses[i];
        float3 n=d.b>0.5 ? float3(0,0,1) : DecodePrepassNormal(pp);
        float agreement=dot(normal,n);
        if (agreement<0.80) continue;
        if (d.b<0.5 && abs(LoadRoughness(pp)-rough)>0.25) continue;
        float3 delta=(IN.wsEyeRay+du*(quv.x-uv.x)+dv*(quv.y-uv.y))*d.r-position;
        float error=max(abs(dot(delta,normal)),abs(dot(delta,n)));
        if (error>tolerance*3.0) continue;
        float w=(o.x?f.x:1-f.x)*(o.y?f.y:1-f.y)*exp(-error/tolerance)*smoothstep(0.80,0.98,agreement);
        float4 s=signals[i];
        if (s.a<0) continue;
        sum+=BrtcHistoryEnergy(s)*w; support+=w;
        float code=BrtcExtractHitCode(s.rgb);
        if (code<62.5 && w*s.a>max(best,1e-5) && w>1e-5) {best=w*s.a;hit=code;}
    }
    return BrtcHistorySignal(sum/max(support,1e-6));
}

float BrtcFindNativeEdgeSeed(PFXVertToPix IN,float2 uv,float4 depth,float3 normal,float rough,float3 du,float3 dv,out float seedCoverage)
{
    float2 size=gAuxSize;
    if(uReuseGuides>0.5)size.x*=0.5;
    int2 centre=(int2)floor((uv-uTraceJitterUV)*size+1e-4);
    float3 position=IN.wsEyeRay*depth.r;
    float footprint=depth.r*max(length(du)/size.x,length(dv)/size.y);
    float tolerance=max(max(footprint*0.20,0.01),depth.r*projParams.y*0.001);
    float best=-1,hit=63;seedCoverage=0;
    [unroll]for(int i=0;i<9;i++)
    {
        int2 q=centre+int2(i%3-1,i/3-1);
        if(any(q<0)||any(q>=(int2)size))continue;
        float4 s=auxTexTex.Load(int3(q,0));
        float code=BrtcExtractHitCode(s.rgb);
        if(s.a<=0.0001||code>=62.5)continue;
        float2 quv=clamp((float2(q)+0.5)/size+uTraceJitterUV,BEAMRT_COH_UV_CLAMP_LO,BEAMRT_COH_UV_CLAMP_HI);
        float4 d=LoadDebugDataPoint(quv);
        if(d.r<=1e-6||d.r>=0.999999||abs(d.b-depth.b)>0.25)continue;
        float4 pp=LoadPrepass(quv);
        float3 n=d.b>0.5?float3(0,0,1):DecodePrepassNormal(pp);
        if(dot(normal,n)<0.80||(d.b<0.5&&abs(LoadRoughness(pp)-rough)>0.25))continue;
        float3 delta=(IN.wsEyeRay+du*(quv.x-uv.x)+dv*(quv.y-uv.y))*d.r-position;
        float error=max(abs(dot(delta,normal)),abs(dot(delta,n)));
        if(error>tolerance*3.0)continue;
        float2 offset=(quv-uv)*size;
        float score=exp(-error/tolerance)*s.a/(1.0+dot(offset,offset));
        if(score>best){best=score;hit=code;seedCoverage=s.a;}
    }
    return BrtcHistoryEncodeDistance(BrtcDecodeHitDistanceCode(hit));
}

float4 CompositeSSR(PFXVertToPix IN, float2 uv, float4 projectionParams)
{
    float3 nativeRayDU=gNativeRayDU;
    float3 nativeRayDV=gNativeRayDV;
    float3 sceneColor = tex2Dlod(sourceTex, float4(uv, 0.0, 0.0)).rgb;
    float3 foggedSceneColor = sceneColor;

#if defined(BEAMRT_COH_SSR_PREPARE)
    float4 ssr = 0;
    float preparedHit=63, preparedSupport=0, preparedConfidence=0, preparedState=3, preparedSeedCoverage=0;
#else
    float4 ssr = BrtcReadCompositeSignal(uv);
#endif

#if defined(BEAMRT_COH_SSR_NO_DEBUG)
    int debugMode = 0;
#else
    int debugMode = (int)uDebugView;
#endif
    if (debugMode >= 44 && debugMode <= 47) return float4(ssr.rgb,1);
    if (debugMode >= 50 && debugMode <= 53)
        return float4(tex2Dlod(debugTex, float4(uv, 0, 0)).rgb, 1);
    if (debugMode == 20)
    {
        float4 rawCurrentSSR = tex2Dlod(debugTex, float4(uv, 0.0, 0.0));
        return float4(rawCurrentSSR.rgb * max(rawCurrentSSR.a, 0.001), 1.0);
    }
    if (debugMode == 21)
        return float4(ssr.rgb * max(ssr.a, 0.001), 1.0);
    if (debugMode == 31 || debugMode == 32 || debugMode == 35 || debugMode == 38 || debugMode == 43)
    {
        return float4(tex2Dlod(debugTex, float4(uv, 0.0, 0.0)).rgb, 1.0);
    }
    if (debugMode == 33)
    {
        float4 packed = tex2Dlod(debugTex, float4(uv, 0.0, 0.0));
        float v = packed.r;
        if (uv.x >= 0.5 && uv.y < 0.5)       v = packed.g;
        else if (uv.x < 0.5 && uv.y >= 0.5)  v = packed.b;
        else if (uv.x >= 0.5 && uv.y >= 0.5) v = packed.a;
        return float4(saturate(v).xxx, 1.0);
    }
    if (debugMode == 22)
    {
        float4 rawCurrentSSR = tex2Dlod(debugTex, float4(uv, 0.0, 0.0));
        if (uUnifiedTemporal>0.5)
            rawCurrentSSR=BrtcUnpackHistory(debugTexTex.Load(BrtcHistoryNearestTexel(uv,gDebugSize,gSourceSize))).signal;
        float3 temporalDelta = abs(ssr.rgb - rawCurrentSSR.rgb) * 8.0;
        temporalDelta += abs(ssr.a - rawCurrentSSR.a) * 2.0;
        return float4(saturate(temporalDelta), 1.0);
    }
    if (debugMode == 23)
    {
        if (uTemporalStrength <= 0.0001)
            return float4(1.0, 0.0, 0.0, 1.0);
        if (uTemporalHistoryValid < 0.5)
            return float4(1.0, 0.0, 1.0, 1.0);
        return (uTemporalReprojectionValid > 0.5)
            ? float4(0.0, 1.0, 0.0, 1.0)
            : float4(1.0, 0.8, 0.0, 1.0);
    }

#if defined(BEAMRT_COH_SSR_NO_DEBUG)
    {
        float4 earlyDepth = LoadDebugDataPoint(uv);
        if (earlyDepth.r >= 0.999999 && earlyDepth.b < 0.0001)
#if defined(BEAMRT_COH_SSR_PREPARE)
            return 0;
#else
            return float4(sceneColor, 1.0);
#endif
    }
#endif

    float rawDepth = LoadRawDepth(uv);
    float realDepth = ndcToRealDepth(rawDepth, projectionParams.zw);
    float4 prepass = LoadPrepass(uv);
    float eyeDepth01 = LoadEyeDepth01FromReal(realDepth, projectionParams);
    bool invalidOpaqueDepth = IsInvalidDepth(rawDepth, realDepth, eyeDepth01);
    float3 normalWS = invalidOpaqueDepth ? float3(0.0, 0.0, 1.0) : DecodePrepassNormal(prepass);
    float roughness = invalidOpaqueDepth ? 1.0 : LoadRoughness(prepass);
    float validSurface = invalidOpaqueDepth ? 0.0 : 1.0;
    if (invalidOpaqueDepth)
        eyeDepth01 = 1.0;
    WaterSurfaceInfo waterInfo = EmptyWaterSurfaceInfo(eyeDepth01, float3(0.0, 0.0, 0.0));
    float waterMask = 0.0;
    float4 combinedDepth = LoadDebugDataPoint(uv);

    if (debugMode == 36)
    {
        float z = dot(IN.wsEyeRay, uCameraForward);
        if (uProjectionValid < 0.5 || z <= 1e-6 || combinedDepth.r >= 0.999999)
            return float4(0.0, 0.0, 0.35, 1.0);
        float2 projectedUV = float2(
            0.5 + dot(IN.wsEyeRay, uCameraRight) / (2.0 * z * max(uTanHalfFovXCur, 1e-4)),
            0.5 - dot(IN.wsEyeRay, uCameraUp) / (2.0 * z * max(uTanHalfFovYCur, 1e-4)));
        float errorPixels = length((projectedUV - uv) * gDepthSize);
        if (uv.x >= 0.5)
        {
            BrtcCacheScreenMapping(IN.wsEyeRay, uv);
            return float4(saturate(abs(gScreenScale - 1.0) * 50.0), saturate(length(gScreenCenter) * 10.0), 1.0);
        }
        float heat = saturate(log2(1.0 + errorPixels) / log2(5.0));
        return float4(saturate(heat * 2.0), saturate(2.0 - heat * 2.0), 0.0, 1.0);
    }

    if (debugMode == 27)
        return float4(saturate(combinedDepth.b).xxx, 1.0);
    if (debugMode == 28)
    {
        float visibleDepth = pow(saturate(combinedDepth.r), 0.25);
        return float4(visibleDepth.xxx, 1.0);
    }
    if (debugMode == 30)
    {
        float mergeGapMeters = max(eyeDepth01 - combinedDepth.r, 0.0) * projectionParams.y;
        return float4(saturate(mergeGapMeters * 0.25),
                      saturate(combinedDepth.b),
                      pow(saturate(combinedDepth.r), 0.25), 1.0);
    }
    if (debugMode == 34)
    {
        return float4(BrtcHiZ0Exposure(combinedDepth).xxx, 1.0);
    }
    if (debugMode == 48)
    {
        return float4(saturate(BrtcHiZ0AO(combinedDepth) / clamp(uEngineAOOpenLevel, 0.5, 1.0)).xxx, 1.0);
    }

    float3 puddleWorldPos = ReconstructWorldPosition(IN, eyeDepth01);
    float pReflect, pDark;
    float puddleMask = BrtcApplyPuddle(puddleWorldPos, normalWS, roughness, pReflect, pDark);

    if (uWaterSSR > 0.5 && combinedDepth.b > 0.0001)
    {
        waterInfo = DecodeCombinedWaterSurface(IN, combinedDepth);
        waterMask = waterInfo.mask;
        validSurface = max(validSurface, waterInfo.mask);
        normalWS = ApplyWaterNormal(normalWS, waterMask, waterInfo.worldPos);
        roughness = lerp(roughness, max(uWaterSSRRoughness, 0.004), waterMask);
    }

    puddleMask *= 1.0 - saturate(waterMask);

    float effectiveRoughness;
    float roughMask = RoughnessMask(roughness, normalWS, effectiveRoughness);
    float glossyRoughMask = roughMask;
    roughMask = saturate(max(roughMask, waterMask * uWaterSSRStrength * waterInfo.angleMask));

    float3 resolveWorldPos = lerp(puddleWorldPos, waterInfo.worldPos, waterMask);
    float3 surfaceToEye = normalize(eyePosWorld - resolveWorldPos);
    float puddleCompositeFresnel = BrtcPuddleFresnelMask(-surfaceToEye, normalWS);
    float puddleResolveMask = roughMask * saturate(uPuddleReflectivity) * pReflect *
                              puddleCompositeFresnel;
    roughMask = saturate(lerp(roughMask, puddleResolveMask, saturate(puddleMask)));
#if defined(BEAMRT_COH_SSR_PREPARE)
    float3 geometricNormal=combinedDepth.b>0.5 ? float3(0,0,1) : DecodePrepassNormal(prepass);
    ssr=BrtcPrepareNativeCurrent(IN,uv,combinedDepth,geometricNormal,
        combinedDepth.b>0.5 ? uWaterSSRRoughness : LoadRoughness(prepass),nativeRayDU,nativeRayDV,preparedHit,preparedSupport);
    preparedHit=BrtcHistoryEncodeDistance(BrtcDecodeHitDistanceCode(preparedHit));
    preparedConfidence=preparedSupport>1e-3 ? 16.0 : 0.0;
    preparedState=preparedSupport>1e-3 ? 0.0 : 3.0;
#endif
    float resolveRealDepth = saturate(combinedDepth.r) * projectionParams.y;
#if !defined(BEAMRT_COH_SSR_PREPARE)
    float detailHit=1023;
    float nativeDetail=0;
    bool detailHistory=uUnifiedTemporal>0.5 && gAuxSize.x<gSourceSize.x*0.99;
    if(detailHistory)
        ssr=BrtcResolveDetailHistory(IN,uv,combinedDepth.r,
            combinedDepth.b>0.5?float3(0,0,1):DecodePrepassNormal(prepass),
            effectiveRoughness,combinedDepth.b>0.5?1.0:0.0,normalWS,detailHit,nativeDetail);
    if (uUnifiedTemporal < 0.5)
        ssr = CheapResolveSSR(uv, projectionParams, ssr, resolveRealDepth, normalWS,
                              effectiveRoughness, roughMask, puddleMask, waterMask);
#endif
    ssr.rgb = BrtcHdrExpand(ssr.rgb);

    float rebuildWeight = (1.0 - smoothstep(0.08, 0.25, effectiveRoughness)) * step(0.5, uPixelRebuild) * validSurface;
#if defined(BEAMRT_COH_SSR_PREPARE)
    [branch]if(uTraceFootprintAA>0.5 && rebuildWeight>0.0001 && effectiveRoughness<0.12 && preparedHit>=1022.5)
        preparedHit=BrtcFindNativeEdgeSeed(IN,uv,combinedDepth,
            combinedDepth.b>0.5?float3(0,0,1):DecodePrepassNormal(prepass),
            combinedDepth.b>0.5?uWaterSSRRoughness:LoadRoughness(prepass),nativeRayDU,nativeRayDV,preparedSeedCoverage);
    rebuildWeight*=max(step(0.0001,ssr.a),max(step(0.0001,preparedSeedCoverage),
        1.0-smoothstep(0.015,0.04,effectiveRoughness)));
    if(uTraceFootprintAA<0.5)rebuildWeight*=step(0.0001,ssr.a);
#else
    rebuildWeight*=max(step(0.0001,ssr.a),1.0-smoothstep(0.015,0.04,effectiveRoughness));
    if(uUnifiedTemporal<0.5)rebuildWeight*=step(0.0001,ssr.a);
#endif
#if !defined(BEAMRT_COH_SSR_PREPARE)
    if (uUnifiedTemporal > 0.5 && !detailHistory) rebuildWeight=0;
    if(detailHistory && uHistoryInterleave>0.5 && (((int)IN.hpos.x&1)==((int)IN.hpos.y&1)))rebuildWeight=0;
    if(detailHistory && uHistoryInterleave>0.5)rebuildWeight*=nativeDetail;
#endif
    bool rebuilt = false;
    float rebuildHitCode = BEAMRT_COH_HIT_DISTANCE_INFINITE;
    [branch]
    if (rebuildWeight > 0.0001)
    {
#if defined(BEAMRT_COH_SSR_PREPARE)
        rebuildHitCode=preparedHit;
#else
        rebuildHitCode = detailHistory ? detailHit : BrtcExtractHitCode(auxTexTex.Load(BrtcTexelAt(uv, gAuxSize, gAuxMaxCoord)).rgb);
#endif
#if defined(BEAMRT_COH_SSR_PREPARE)
        rebuildWeight *= step(rebuildHitCode,1022.5);
#else
        rebuildWeight *= step(rebuildHitCode, detailHistory ? 1022.5 : BEAMRT_COH_HIT_DISTANCE_INFINITE - 0.5);
#endif
    }
    [branch]
    if (rebuildWeight > 0.0001)
    {
        float3 rebuildDir = normalize(reflect(-surfaceToEye, normalWS));
        float3 rebuiltColor;
        float2 rebuiltUV;
#if defined(BEAMRT_COH_SSR_PREPARE)
        float seedDistance=BrtcHistoryDecodeDistance(rebuildHitCode);
#else
        float seedDistance=detailHistory ? BrtcHistoryDecodeDistance(rebuildHitCode) : BrtcDecodeHitDistanceCode(rebuildHitCode);
#endif
        rebuilt = BrtcRebuildReflection(IN, uv, resolveWorldPos, rebuildDir,
                                       seedDistance, rebuiltColor, rebuiltUV);
        if (rebuilt)
        {
            float fade=EdgeFade(rebuiltUV);
            float2 border=min(rebuiltUV,1.0-rebuiltUV)*gSourceSize;
            float traceFootprint=max(gSourceSize.x/max(uResolution.x,1.0),gSourceSize.y/max(uResolution.y,1.0));
            fade*=smoothstep(0.0,2.0*max(traceFootprint,1.0),min(border.x,border.y));
            ssr.rgb = lerp(ssr.rgb, rebuiltColor, rebuildWeight*fade);
#if defined(BEAMRT_COH_SSR_PREPARE)
            float d=LoadDebugDataPoint(rebuiltUV).r;
            float3 reflectedPoint=eyePosWorld+(IN.wsEyeRay+nativeRayDU*(rebuiltUV.x-uv.x)+nativeRayDV*(rebuiltUV.y-uv.y))*d;
            preparedHit=BrtcHistoryEncodeDistance(length(reflectedPoint-resolveWorldPos));
            preparedConfidence=lerp(preparedConfidence,31.0,rebuildWeight*fade);
            preparedState=1.0;
            float response=roughMask*FresnelMask(-surfaceToEye,normalWS)*FacingFade(rebuildDir,normalWS);
            response*=fade*DistanceFade(length(reflectedPoint-resolveWorldPos));
            float3 hn=LoadDebugDataPoint(rebuiltUV).b>0.5 ? float3(0,0,1) : DecodePrepassNormal(LoadPrepass(rebuiltUV));
            response*=smoothstep(-0.2,max(uBackfaceFade,0.001),dot(hn,-rebuildDir));
            response*=1.0-smoothstep(uSkyFadeStart,uSkyFadeEnd,d);
            if(ssr.a<=0.0001 && preparedSeedCoverage>0.0001)
            {
                float recover=1.0-smoothstep(0.08,0.12,effectiveRoughness);
                ssr.a=min(saturate(response),preparedSeedCoverage)*rebuildWeight*recover;
            }
            float mirrorCoverage=1.0-smoothstep(0.015,0.04,effectiveRoughness);
            ssr.a=lerp(ssr.a,saturate(response),rebuildWeight*mirrorCoverage);
            ssr.a*=lerp(1.0,fade,rebuildWeight*(1.0-mirrorCoverage));
#endif
        }
#if defined(BEAMRT_COH_SSR_PREPARE)
        else { preparedConfidence=min(preparedConfidence,4.0); preparedState=2.0; }
#endif
    }
#if !defined(BEAMRT_COH_SSR_NO_DEBUG)
    if (debugMode == 49)
    {
        if (uUnifiedTemporal>0.5)
        {
            BrtcHistory t=BrtcUnpackHistory(auxTexTex.Load(BrtcHistoryNearestTexel(uv,gAuxSize,gSourceSize)));
            return float4(t.misses/7.0,t.hit<1022.5 ? t.age/31.0 : 0.0,0,1);
        }
        return float4(rebuildWeight <= 0.0001 ? float3(0.0, 0.0, 0.0)
            : (rebuilt ? float3(0.0, rebuildWeight, 0.0) : float3(rebuildWeight, 0.0, 0.0)), 1.0);
    }
#endif

#if defined(BEAMRT_COH_SSR_PREPARE)
    float3 historyNormal=normalWS;
    if (combinedDepth.b>0.5) historyNormal=float3(0,0,1);
    return BrtcPackHistory(float4(BrtcHdrCompress(ssr.rgb),ssr.a),combinedDepth.r,historyNormal,
        preparedConfidence,preparedHit,combinedDepth.b>0.5 ? 1.0 : 0.0,preparedState,effectiveRoughness);
#endif
    if (uReflectionEdgeFade > 0.001 && ssr.a > 0.0001)
    {
        float2 auxTexel = 1.0 / max(gAuxSize, float2(1.0, 1.0));
        float na = 0.0;
        na += BrtcReadCompositeSignal(clamp(uv + float2( auxTexel.x, 0.0), BEAMRT_COH_UV_CLAMP_LO, BEAMRT_COH_UV_CLAMP_HI)).a;
        na += BrtcReadCompositeSignal(clamp(uv + float2(-auxTexel.x, 0.0), BEAMRT_COH_UV_CLAMP_LO, BEAMRT_COH_UV_CLAMP_HI)).a;
        na += BrtcReadCompositeSignal(clamp(uv + float2(0.0,  auxTexel.y), BEAMRT_COH_UV_CLAMP_LO, BEAMRT_COH_UV_CLAMP_HI)).a;
        na += BrtcReadCompositeSignal(clamp(uv + float2(0.0, -auxTexel.y), BEAMRT_COH_UV_CLAMP_LO, BEAMRT_COH_UV_CLAMP_HI)).a;
        na *= 0.25;
        float coverage = saturate(na / max(ssr.a, 0.0001));
        ssr.a *= lerp(1.0, coverage, saturate(uReflectionEdgeFade));
    }

    float3 viewToSurface = -surfaceToEye;
    float3 skyReflectDir = normalize(reflect(viewToSurface, normalWS));
    float fresnelMask = FresnelMask(viewToSurface, normalWS);
    float facingMask = FacingFade(skyReflectDir, normalWS);
    float skyStrength = saturate(uSkyReflectionFallback);
    float waterSkyStrength = saturate(uWaterSkyFallback);
    float ordinaryMask = (1.0 - saturate(waterMask)) * (1.0 - saturate(puddleMask));
    float lightExposure = BrtcHiZ0Exposure(combinedDepth);
    float screenEnvironment = 0.0;
    float3 skyColor = float3(0.0, 0.0, 0.0);
    float fillBound = validSurface * max(skyStrength * glossyRoughMask * fresnelMask * facingMask * ordinaryMask,
        waterSkyStrength * waterMask * saturate(uWaterSSRStrength) * waterInfo.angleMask);
    bool puddleNeedsEnvironment = puddleMask > 0.0001 && uPuddleEnvironmentStrength > 0.0001;
    if (fillBound > saturate(ssr.a) + 0.0001 || puddleNeedsEnvironment || debugMode == 40)
        skyColor = BrtcEnvironmentColor(skyReflectDir, lightExposure, effectiveRoughness,
            BrtcScreenCenterFromPoint(puddleWorldPos, uv), float2(1.0, 1.0), screenEnvironment);
    float upwardRay = BrtcEnvironmentGate(smoothstep(0.02, 0.24, skyReflectDir.z), screenEnvironment);
    float upwardSurface = BrtcEnvironmentGate(smoothstep(0.05, 0.45, normalWS.z), screenEnvironment);

    float environmentOcclusion = BrtcEnvironmentOcclusion(BrtcHiZ0AO(combinedDepth),
        dot(normalWS, surfaceToEye), effectiveRoughness);
    float glossySky = validSurface * glossyRoughMask * fresnelMask * facingMask * upwardRay *
                      upwardSurface * ordinaryMask * skyStrength * environmentOcclusion;
    float waterSky = validSurface * waterMask * saturate(uWaterSSRStrength) * waterInfo.angleMask *
                     max(fresnelMask, 0.35) * max(facingMask, 0.45) * upwardRay * waterSkyStrength;

    float puddleCoatResponse = validSurface * puddleResolveMask * facingMask * upwardRay;
    float puddleEnvironmentCoverage = saturate(uPuddleEnvironmentStrength) *
                                      step(0.0001, puddleMask) *
                                      step(0.0001, puddleCoatResponse);

    float environmentResponse = saturate(max(glossySky, waterSky));

    ssr = BrtcBlendEnvironmentFill(ssr, environmentResponse, skyColor);

    float puddleActive = step(0.0001, puddleMask);
    float puddleSSRConfidence = saturate(ssr.a / max(puddleCoatResponse, 0.04)) *
                                puddleActive;
    float puddleEnvironmentFill = (1.0 - puddleSSRConfidence) *
                                  saturate(uPuddleEnvironmentStrength) * puddleActive *
                                  environmentOcclusion;
    float puddleTotalCoverage = saturate(puddleSSRConfidence + puddleEnvironmentFill);
    float puddleSourceWeight = puddleSSRConfidence + puddleEnvironmentFill;
    float3 puddleLayerColor = (ssr.rgb * puddleSSRConfidence +
                               skyColor * puddleEnvironmentFill) /
                              max(puddleSourceWeight, 0.0001);

    if (debugMode == 24)
        return float4(saturate(glossySky), saturate(waterSky), saturate(screenEnvironment), 1.0);
    if (debugMode == 42)
    {
        float2 v = LoadDebugDataPoint(uv).xy;
        return float4(abs(v) * 50.0, 0.0, 1.0);
    }
    if (debugMode == 41)
    {
        return float4(max(LoadDebugDataPoint(uv).rgb, 0.0) * 4.0, 1.0);
    }
    if (debugMode == 40)
    {
        return (uv.x < 0.5)
            ? float4(max(ambientSH9[0].rgb, 0.0) * 3.0, 1.0)
            : float4(skyColor, 1.0);
    }
    if (debugMode == 25)
        return float4(saturate(puddleMask), saturate(puddleCoatResponse),
                      saturate(puddleTotalCoverage), 1.0);
    if (debugMode == 26)
        return float4(saturate(puddleCoatResponse), saturate(puddleSSRConfidence),
                      saturate(puddleEnvironmentFill), 1.0);
    if (puddleMask > 0.001 && uPuddleDarken > 0.001)
    {
        float adaptiveDarken = saturate(uPuddleDarken) * puddleMask * pDark *
                               lerp(0.15, 1.0, puddleSSRConfidence);
        sceneColor *= 1.0 - saturate(adaptiveDarken);
    }

    float puddleLayerAlpha = puddleCoatResponse * puddleTotalCoverage;
    float ordinaryWeight = 1.0 - saturate(puddleMask);
    float puddleWeight = saturate(puddleMask);
    float combinedReflectionAlpha = ssr.a * ordinaryWeight +
                                    puddleLayerAlpha * puddleWeight;
    float3 combinedReflectionColor =
        (ssr.rgb * ssr.a * ordinaryWeight +
         puddleLayerColor * puddleLayerAlpha * puddleWeight) /
        max(combinedReflectionAlpha, 0.0001);
    float alpha = saturate(combinedReflectionAlpha * uAmount);
    float detailKeep = saturate(uSurfaceDetail) * smoothstep(0.08, 0.35, effectiveRoughness) *
                       (1.0 - saturate(waterMask)) * (1.0 - saturate(puddleMask));
    float3 sceneBase = sceneColor;
    [branch]
    if (detailKeep > 0.001 && alpha > 0.001)
    {
        float2 o = 1.5 / max(gSourceSize, float2(1.0, 1.0));
        float3 low = 0.25 * (tex2Dlod(sourceTex, float4(uv + float2( o.x,  o.y), 0.0, 0.0)).rgb +
                             tex2Dlod(sourceTex, float4(uv + float2(-o.x,  o.y), 0.0, 0.0)).rgb +
                             tex2Dlod(sourceTex, float4(uv + float2( o.x, -o.y), 0.0, 0.0)).rgb +
                             tex2Dlod(sourceTex, float4(uv + float2(-o.x, -o.y), 0.0, 0.0)).rgb);
        sceneBase = lerp(sceneColor, low, detailKeep);
    }
    float3 reflected = max(sceneColor + (combinedReflectionColor - sceneBase) *
                           saturate(alpha * uIntensity), 0.0);

    reflected = BrtcApplyAddedWaterTint(reflected, waterMask, waterInfo.angleMask);

    reflected = lerp(
        foggedSceneColor, reflected,
        BrtcSSRViewFogTransport(resolveWorldPos, validSurface));

    if ((int)uDebugView == 1)
        return float4(ssr.rgb * max(ssr.a, 0.001), 1.0);
    if ((int)uDebugView == 2)
        return float4(ssr.a.xxx, 1.0);
    if ((int)uDebugView == 4)
        return float4(normalWS * 0.5 + 0.5, 1.0);
    if ((int)uDebugView == 6)
        return float4(roughMask.xxx, 1.0);
    if ((int)uDebugView == 8)
        return float4(effectiveRoughness.xxx, 1.0);
    if ((int)uDebugView == 16)
    {
        return float4((waterInfo.angleMask * waterMask).xxx, 1.0);
    }
    if ((int)uDebugView == 18)
    {
        return float4(puddleMask.xxx, 1.0);
    }
    if ((int)uDebugView == 19)
    {
        return float4(BrtcTerrainPuddle(puddleWorldPos).xxx, 1.0);
    }

    return float4(reflected, 1.0);
}

#endif
