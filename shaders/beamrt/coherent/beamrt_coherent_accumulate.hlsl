#ifndef BEAMRT_COH_SSR_ACCUMULATE_HLSL
#define BEAMRT_COH_SSR_ACCUMULATE_HLSL

float BrtcHistoryFreshWeight(float age, float retention)
{
    float requested = 1.0 - clamp(retention, 0.0, 0.98);
    // Five packed age bits describe warmup, not a permanent 32-frame limit.
    // Once mature, honor the requested EMA retention. Geometry rejection,
    // color clipping and motion can still increase fresh weight below.
    float warmup = age >= 30.5 ? 0.0 : 1.0 / (max(age, 0.0) + 1.0);
    return max(requested, warmup);
}

float BrtcCoverageClampRadius(float baseRadius, float historyAlpha, float sampleCount, float rough, float water)
{
    float a = saturate(historyAlpha);
    // Sparse GGX hits are intermittent measurements, not a solid black surface.
    // A bounded Bernoulli-inspired floor avoids clipping mature coverage to a
    // zero-hit neighborhood every frame. Heuristic, not independent-sample proof.
    float sparseRadius = 2.5 * sqrt(max(a * (1.0-a), 0.01) / max(sampleCount, 1.0));
    return lerp(baseRadius, max(baseRadius, sparseRadius), BrtcRoughStabilityWeight(rough, water));
}

bool BrtcHistoryCompatible(BrtcHistory t, float3 receiverPoint, float3 normal, float water,
                          float rough, float3 samplePoint, float tolerance)
{
    if (t.age < 0.5 || t.depth <= 1e-6 || t.depth >= 0.999999 || abs(t.water - water) > 0.5)
        return false;
    if (dot(normal, t.normal) < 0.75 || abs(t.rough - rough) > 0.30) return false;
    float3 delta = samplePoint - receiverPoint;
    return max(abs(dot(delta, normal)), abs(dot(delta, t.normal))) <= tolerance;
}

float4 BrtcGatherNativeHistory(BrtcPrevCamera cam, float2 historyUV, float3 receiverPoint,
    float3 normal, float water, float rough, float expectedDepth,
    out float age, out float hit, out float misses, out float accepted)
{
    float3 ro, du, dv;
    BrtcPrevCameraRays(cam, ro, du, dv);
    float footprint = expectedDepth * max(length(du) / gAuxSize.x, length(dv) / gAuxSize.y);
    float tolerance = max(0.012, expectedDepth * projParams.y * 0.0015) + footprint * 0.5;
    float4 energy = 0.0;
    accepted = 0; age = 0; hit = 1023; misses = 0;
    float best = -1;
    [unroll] for (int i = 0; i < 4; i++)
    {
        int2 q;float w;
        BrtcHistoryGatherTap(historyUV,gAuxSize,gDepthSize,i,q,w);
        if (w < 1e-4 || any(q < 0) || any(q > (int2)gAuxMaxCoord)) continue;
        BrtcHistory t = BrtcUnpackHistory(auxTexTex.Load(int3(q,0)));
        float2 quv = BrtcHistoryReceiverUV(q,gAuxSize,gDepthSize);
        float3 ray = ro + du * quv.x + dv * quv.y;
        float3 samplePoint = cam.eye + ray * t.depth;
        if (!BrtcHistoryCompatible(t, receiverPoint, normal, water, rough, samplePoint, tolerance)) continue;
        float denominator=dot(ray,normal);
        if (abs(denominator)<1e-8 || dot(receiverPoint-cam.eye,normal)*denominator<=0) continue;
        energy += BrtcHistoryEnergy(t.signal) * w;
        age += t.age * w;
        accepted += w;
        if (w > best) { best = w; hit = t.hit; misses = t.misses; }
    }
    age /= max(accepted, 1e-6);
    return energy / max(accepted, 1e-6);
}

float4 BrtcAccumulateNative(PFXVertToPix IN, float2 uv)
{
    int2 pixel = (int2)IN.hpos.xy;
    BrtcHistory current = BrtcUnpackHistory(sourceTexTex.Load(int3(pixel,0)));
    float3 receiverPoint = ReconstructWorldPosition(IN, current.depth);
    float3 du = gNativeRayDU;
    float3 dv = gNativeRayDV;
    bool receiverValid = current.depth > 1e-6 && current.depth < 0.999999;
    if (!receiverValid) return 0;
    bool hasCurrent = current.age > 0.5;
    bool reliableHit=hasCurrent && current.hit<1022.5 && current.misses!=2.0;
    float4 energy = hasCurrent ? BrtcHistoryEnergy(current.signal) : float4(0,0,0,0);
    float confidence = current.age / 31.0;
    float outAge = hasCurrent ? 1.0 : 0.0;
    float outMisses = reliableHit ? 0.0 : 1.0;
    float outHit = hasCurrent ? current.hit : 1023.0;
    float historyWeight = 0, clipDistance = 0, geometryConfidence = 0;
    int motionSource = BEAMRT_COH_MOTION_CAMERA;

    if (uTemporalHistoryValid > 0.5)
    {
        bool velocity = uVelocityValid > 0.5 && current.water < 0.5;
        BrtcPrevCamera cam = BrtcEmptyPreviousCamera();
        if (uCameraHistoryValid > 0.5)
        {
            if (uVelocityValid > 0.5) cam=BrtcLoadPreviousCameraFrom(terrainTexTex,projParams);
            else cam=BrtcLoadPreviousCameraFrom(debugTexTex,projParams);
        }
        float2 staticUV=uv;
        float expectedDepth=0;
        bool solved = cam.valid && BrtcSolvePreviousUV(cam, receiverPoint - cam.eye, staticUV, expectedDepth);
        float2 surfaceUV = staticUV;
        float3 previousPoint = receiverPoint;
        float3 previousNormal = current.normal;
        bool moving = false;
        if (velocity && solved)
        {
            surfaceUV = uv + LoadDebugDataPoint(uv).xy;
            moving = length((surfaceUV - staticUV) * gDepthSize) > 0.75;
            motionSource = BEAMRT_COH_MOTION_ENGINE;
        }
        if (solved && uVehicleHalf.w > 0.5)
        {
            float3 local;
            bool onVehicle = uMotionOptions.x > 0.5 && BrtcOnPlayerVehicle(receiverPoint, local);
            if (onVehicle && (!velocity || !moving))
            {
                previousPoint = BrtcPlayerVehiclePrevious(local);
                float3 localNormal = float3(dot(current.normal,uVehicleAxisX.xyz), dot(current.normal,uVehicleAxisY.xyz), dot(current.normal,uVehicleAxisZ.xyz));
                previousNormal = normalize(uVehiclePrevAxisX.xyz * localNormal.x + uVehiclePrevAxisY.xyz * localNormal.y + uVehiclePrevAxisZ.xyz * localNormal.z);
                solved = BrtcSolvePreviousUV(cam, previousPoint - cam.eye, surfaceUV, expectedDepth);
                float footprint = current.depth * max(length(du)/gDepthSize.x,length(dv)/gDepthSize.y);
                moving = BrtcRigidReceiverMoved(receiverPoint,previousPoint,footprint);
                if (moving) motionSource = BEAMRT_COH_MOTION_VEHICLE;
            }
            else if (!onVehicle && uMotionOptions.y > 0.5 &&
                     BrtcPlayerVehicleUncovered(cam.eye, receiverPoint, BuildProjectionBasis(IN, uv, receiverPoint)))
            { solved = false; motionSource = BEAMRT_COH_MOTION_DISOCCLUDED; }
        }
        if (solved)
        {
            float age=0, hit=1023, misses=0, accepted=0;
            float2 fetchUV = surfaceUV;
            float virtualWeight = (!moving && uVirtualReprojection > 0.5)
                ? 1.0 - smoothstep(uVirtualRoughStart,max(uVirtualRoughEnd,uVirtualRoughStart+0.01),current.rough) : 0.0;
            bool directVirtual=virtualWeight>=0.99999 && reliableHit;
            float4 history=0;
            if (!directVirtual)
                history=BrtcGatherNativeHistory(cam,surfaceUV,previousPoint,previousNormal,
                    current.water,current.rough,expectedDepth,age,hit,misses,accepted);
            bool virtualAccepted=false;
            if (virtualWeight > 0.001)
            {
                float candidate=reliableHit ? current.hit : 1023.0;
                if ((!reliableHit || candidate>=1022.5) && accepted>0.05 && misses<6.5 && confidence<0.75)
                    candidate=hit;
                float3 viewDir=normalize(receiverPoint-eyePosWorld);
                float2 virtualUV; float virtualDepth;
                bool ok=candidate<1022.5
                    ? BrtcSolvePreviousUV(cam,receiverPoint+viewDir*BrtcHistoryDecodeDistance(candidate)-cam.eye,virtualUV,virtualDepth)
                    : BrtcSolvePreviousUV(cam,viewDir,virtualUV,virtualDepth);
                if (ok)
                {
                    virtualUV=BrtcScaleReflectionTranslation(surfaceUV,virtualUV);
                    float va,vh,vm,vw;
                    float4 v=BrtcGatherNativeHistory(cam,virtualUV,previousPoint,previousNormal,
                        current.water,current.rough,expectedDepth,va,vh,vm,vw);
                    if (vw>0.05)
                    {
                        virtualAccepted=true;
                        float blend=accepted>0.05 ? virtualWeight : 1.0;
                        history=lerp(history,v,blend);age=lerp(age,va,blend);
                        accepted=lerp(accepted,vw,blend);
                        if (blend>0.5) {hit=vh;misses=vm;fetchUV=virtualUV;}
                    }
                }
            }
            if (directVirtual && !virtualAccepted)
                history=BrtcGatherNativeHistory(cam,surfaceUV,previousPoint,previousNormal,
                    current.water,current.rough,expectedDepth,age,hit,misses,accepted);
            geometryConfidence = accepted;
            if (accepted > 0.05 && age >= 0.5)
            {
                float footprint = current.depth * max(length(du)/gSourceSize.x,length(dv)/gSourceSize.y);
                float tolerance = max(0.012,current.depth*projParams.y*0.0015) + footprint*0.5;
                float4 mean = 0, sq = 0;
                float4 closeSignal=BrtcHistorySignal(history);
                float3 closeDelta=abs(closeSignal.rgb-current.signal.rgb)/max(max(closeSignal.rgb,current.signal.rgb),0.01);
                bool stable=uAdaptiveDenoising>0.5 && hasCurrent && accepted>0.95 && age>=8.0 &&
                    ((max(max(abs(history.x-energy.x),abs(history.y-energy.y)),max(abs(history.z-energy.z),abs(history.w-energy.w)))<1e-6) ||
                    (confidence>0.99 && current.misses==1.0 && max(max(closeDelta.x,closeDelta.y),closeDelta.z)<0.025 && abs(history.a-current.signal.a)<0.02));
                float count=stable ? 1.0 : 0.0;
                float3 colorMean=0, colorSq=0;
                float colorCount=0;
                float hitLuma = 0, hitWeight = 0, hitMax = 0;
                int2 statsStep=max(int2(1,1),(int2)round(gSourceSize/max(uResolution,1.0)));
                tolerance+=footprint*0.25*max(statsStep.x,statsStep.y);
                [branch] if (hasCurrent && !stable)
                {
                    [unroll] for (uint j = 0u; j < 9u; j++)
                    {
                        if (uAdaptiveDenoising>0.5 && current.rough<0.15 && (j==0 || j==2 || j==6 || j==8)) continue;
                        int2 q = pixel + int2((int)(j%3u)-1,(int)(j/3u)-1)*statsStep;
                        if (any(q < 0) || any(q > (int2)gSourceMaxCoord)) continue;
                        BrtcHistory t = BrtcUnpackHistory(sourceTexTex.Load(int3(q,0)));
                        float2 quv = BrtcHistoryReceiverUV(q,gSourceSize,gDepthSize);
                        float3 qp = eyePosWorld + (IN.wsEyeRay + du*(quv.x-uv.x) + dv*(quv.y-uv.y))*t.depth;
                        if (!BrtcHistoryCompatible(t,receiverPoint,current.normal,current.water,current.rough,qp,tolerance)) continue;
                        float4 e = BrtcHistoryEnergy(t.signal);
                        mean += e; sq += e*e; count += 1;
                        if (t.signal.a>1e-4)
                        {
                            colorMean+=t.signal.rgb;
                            colorSq+=t.signal.rgb*t.signal.rgb;
                            colorCount+=1.0;
                        }
                        if (current.rough>0.08 && uFireflySuppression>0.0001 && j != 4 && t.hit < 1022.5 && t.signal.a > 0.01)
                        {
                            float l = BrtcLuma(BrtcHdrExpand(t.signal.rgb));
                            hitLuma += l*t.signal.a; hitWeight += t.signal.a; hitMax=max(hitMax,l);
                        }
                    }
                    if (hasCurrent && hitWeight > 0.05 && current.rough > 0.08)
                    {
                        float3 hdr = BrtcHdrExpand(current.signal.rgb);
                        hdr *= BrtcFireflyWeight(hdr,max(hitLuma/hitWeight,hitMax*0.5));
                        current.signal.rgb = BrtcHdrCompress(hdr);
                        energy = BrtcHistoryEnergy(current.signal);
                    }
                }
                if (hasCurrent && count > 0)
                {
                    if (!stable)
                    {
                        mean /= count;
                        float4 sigma = sqrt(max(sq/count-mean*mean,0.0));
                        float gamma = 1.25 + 1.5*saturate(uTemporalClamp);
                        colorMean/=max(colorCount,1.0);
                        float3 colorSigma=sqrt(max(colorSq/max(colorCount,1.0)-colorMean*colorMean,0.0));
                        float3 colorHalf=gamma*colorSigma+max(abs(colorMean)*0.04,0.0001);
                        float4 historySignal=BrtcHistorySignal(history);
                        float3 delta=historySignal.rgb-colorMean;
                        // No observed hit colors cannot establish a color mismatch.
                        float outside=colorCount>0.0 ? max(max(abs(delta.x)/colorHalf.x,abs(delta.y)/colorHalf.y),abs(delta.z)/colorHalf.z) : 1.0;
                        float3 clippedColor=colorCount>0.0 ? colorMean+delta/max(outside,1.0) : historySignal.rgb;
                        float alphaHalf=gamma*sigma.a+0.025;
                        alphaHalf=BrtcCoverageClampRadius(alphaHalf,history.a,count,current.rough,current.water);
                        float clippedAlpha=clamp(history.a,max(mean.a-alphaHalf,0.0),min(mean.a+alphaHalf,1.0));
                        float4 clipped=BrtcHistoryEnergy(float4(clippedColor,clippedAlpha));
                        clipDistance = saturate((outside-1.0)/2.0);
                        history = lerp(history,clipped,confidence);
                        age = max(1.0,age*(1.0-clipDistance*confidence));
                    }
                    float fresh = BrtcHistoryFreshWeight(age,uTemporalStrength);
                    fresh = max(fresh,1.0-accepted);
                    float2 infUV; float infDepth;
                    if (BrtcSolvePreviousUV(cam,IN.wsEyeRay,infUV,infDepth))
                    {
                        float translation = length((fetchUV-infUV)*gDepthSize);
                        float rotation = length((infUV-uv)*gDepthSize);
                        float motion = exp(-0.04*(translation*max(uTemporalMotionRejection,0.0)*
                            lerp(1.0,saturate(uVirtualMotionScale),virtualWeight*saturate(uVirtualParallaxScale))+rotation*max(uTemporalMotionRejectionRot,0.0)));
                        fresh=max(fresh,1.0-motion);
                    }
                    fresh = saturate(fresh * max(confidence,0.125));
                    if (moving) fresh=max(fresh,0.20);
                    historyWeight=1.0-fresh;
                    energy=lerp(history,energy,fresh);
                    if (current.misses==1.0 && hasCurrent)
                    {
                        float glossy=1.0-smoothstep(0.08,0.25,current.rough);
                        float travel=length((fetchUV-uv)*gDepthSize);
                        float colorFresh=max(fresh,glossy*smoothstep(0.5,2.0,travel)*confidence);
                        float4 hs=BrtcHistorySignal(history);
                        float3 color=lerp(hs.rgb,current.signal.rgb,colorFresh);
                        float alpha=lerp(hs.a,current.signal.a,fresh);
                        energy=BrtcHistoryEnergy(float4(color,alpha));
                    }
                    outAge=min(age+1.0,31.0);
                }
                else
                {
                    energy=history*0.94;
                    historyWeight=0.94;
                    outAge=max(age-1.0,1.0);
                }
                outMisses=reliableHit ? 0.0 : min(misses+1.0,7.0);
                if ((!reliableHit || current.hit>=1022.5) && outMisses<7.0 && accepted>0.5 && !moving)
                    outHit=hit;
                if (!reliableHit && outMisses>=7.0) outHit=1023.0;
                if (!hasCurrent && outMisses>=7.0) { energy=0; outAge=0; outHit=1023; }
            }
        }
    }
    if (BEAMRT_COH_TEMPORAL_DEBUG_VIEW == 44) return float4(1-geometryConfidence,geometryConfidence,0,1);
    if (BEAMRT_COH_TEMPORAL_DEBUG_VIEW == 45) return float4(historyWeight.xxx,1);
    if (BEAMRT_COH_TEMPORAL_DEBUG_VIEW == 46) return float4(clipDistance,outMisses/7.0,0,1);
    if (BEAMRT_COH_TEMPORAL_DEBUG_VIEW == 47) return float4(BrtcMotionSourceColor(motionSource),1);
    return BrtcPackHistory(BrtcHistorySignal(energy),current.depth,current.normal,outAge,
                          outHit,current.water,outMisses,current.rough);
}
#endif
