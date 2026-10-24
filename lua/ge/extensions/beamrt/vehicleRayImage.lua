-- Fixed-view CPU geometry images (identity/depth or isolated normal close-ups).
-- Not a game camera, reflection,
-- material shader, opaque visibility result or GPU performance demonstration.
local M={width=64,height=40,operationsPerUpdate=16384}
local bvh=require('ge/extensions/beamrt/vehicleGeometryBVH')
local rays=require('ge/extensions/beamrt/vehicleRayProbe')
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function dot(a,b)return a[1]*b[1]+a[2]*b[2]+a[3]*b[3]end
local function cross(a,b)return {a[2]*b[3]-a[3]*b[2],a[3]*b[1]-a[1]*b[3],a[1]*b[2]-a[2]*b[1]}end
local function detached(value)
  if type(value)~='table' then return value end
  local out={};for k,v in pairs(value)do out[k]=detached(v)end;return out
end
local function unit(v)
  local length=math.sqrt(dot(v,v));assert(finite(length) and length>1e-6,'Degenerate fixed-view basis')
  return {v[1]/length,v[2]/length,v[3]/length}
end
local function frame(db,poses,widthPixels,heightPixels,bounds,detail)
  local a,b=poses[1].center,poses[2].center
  local right=unit({b[1]-a[1],b[2]-a[2],0})
  local horizontal=cross({0,0,1},right)
  local direction=unit({horizontal[1]+(detail and .6 or 0)*right[1],
    horizontal[2]+(detail and .6 or 0)*right[2],detail and -.5 or -.35})
  if detail then right=unit(cross(direction,{0,0,1}))end
  local up=unit(cross(right,direction))
  local lo,hi={math.huge,math.huge,math.huge},{-math.huge,-math.huge,-math.huge}
  for mask=0,7 do
    local p={}
    for j=1,3 do
      local low=math.floor(mask/2^(j-1))%2==0
      p[j]=bounds and (low and bounds.lo[j] or bounds.hi[j]) or tonumber(db.bounds[low and j-1 or j+2])
    end
    local v={dot(p,right),dot(p,up),dot(p,direction)}
    for j=1,3 do lo[j]=math.min(lo[j],v[j]);hi[j]=math.max(hi[j],v[j])end
  end
  local margin=detail and 1.06 or 1.1
  local width,height=(hi[1]-lo[1])*margin,(hi[2]-lo[2])*margin
  height=math.max(height,width*heightPixels/widthPixels,.1);width=height*widthPixels/heightPixels
  local near=lo[3]-2;local far=hi[3]-near+2
  assert(far>.16 and far<=1000,'Fixed-view segment out of range')
  return {right=right,up=up,direction=direction,width=width,height=height,
    centerX=(lo[1]+hi[1])*.5,centerY=(lo[2]+hi[2])*.5,near=near,far=far,
    pixelWidth=widthPixels,pixelHeight=heightPixels}
end
local function origin(f,x,y)
  local px=f.centerX+((x+.5)/f.pixelWidth-.5)*f.width
  local py=f.centerY+(.5-(y+.5)/f.pixelHeight)*f.height
  local p={};for j=1,3 do p[j]=f.right[j]*px+f.up[j]*py+f.direction[j]*f.near end
  return p
end
local palette={{25,225,255},{255,50,195}}
function M.create(scenes,poses,profile,cameraSnapshot,gpuEndpoint)
  if profile==nil then profile='identity'end
  assert(profile=='identity' or profile=='normals' or profile=='bounce' or profile=='camera-bounce' or profile=='camera-material' or profile=='camera-gpu' or profile=='camera-gpu-image','Unsupported image profile')
  local detail=profile=='normals'
  local surface=profile=='camera-material'
  local gpuImage=profile=='camera-gpu-image'
  local cameraView=profile=='camera-bounce' or surface or profile=='camera-gpu' or gpuImage
  local bounce=profile=='bounce' or cameraView
  if cameraView then assert(cameraSnapshot and cameraSnapshot.projectionValidated,'Validated camera snapshot required')end
  local job={phase='building',elapsed=0,workOperations=0,build={},trace={nodeTests=0,triangleTests=0},
    profile=profile,cameraSnapshot=cameraView and cameraSnapshot or nil,
    pixels={},pixelsRendered=0,hits={0,0},width=cameraView and ((surface or gpuImage) and 256 or 128) or (bounce and 192 or (detail and 256 or M.width)),
    height=cameraView and cameraSnapshot.sampleHeight*2 or (bounce and 128 or (detail and 96 or M.height)),
    panelWidth=cameraView and 128 or (bounce and 96 or (detail and 128 or M.width)),
    frontFacePixels=0,backFacePixels=0,
    acceleratorMatchesReference=false,
    controls=rays.create(scenes,poses),fullPrimitiveReferences=true}
  job.co=coroutine.create(function()
    local spent=0
    local function work()
      spent=spent+1;job.workOperations=job.workOperations+1
      if spent>=M.operationsPerUpdate then spent=0;coroutine.yield()end
    end
    if surface then
      job.phase='capturing-materials'
      job.materialSnapshot=require('ge/extensions/beamrt/vehicleMaterialSnapshot').capture(scenes)
    end
    local db=bvh.build(scenes,work,job.build)
    job.phase='reference-controls'
    spent=0;coroutine.yield() -- do not stack a full reference batch on build work
    while job.controls.phase=='running' do
      rays.advance(job.controls,0) -- the image job owns the real-time deadline
      coroutine.yield()
    end
    assert(rays.status(job.controls).geometricControlsPassed,'Four CPU reference controls did not pass')
    job.phase='checking-bvh'
    for i,ray in ipairs(job.controls.rays)do
      local fast=bvh.trace(db,ray.origin,ray.direction,ray.length,ray.excludedVehicleId,work,job.trace)
      local slow=job.controls.results[i].hit
      assert((fast~=nil)==(slow~=nil),'BVH/reference hit-miss mismatch')
      if fast then
        assert(fast.vehicleId==slow.vehicleId and fast.kind==slow.kind and fast.nativeIndex==slow.nativeIndex
          and fast.primitive==slow.primitive and fast.triangleInPrimitive==slow.triangleInPrimitive
          and math.abs(fast.distance-slow.distance)<1e-5,'BVH/reference nearest primitive mismatch')
      end
    end
    job.acceleratorMatchesReference=true
    -- All source CPU buffers are now unnecessary: the BVH has independent
    -- world-space double arrays. Retain only small control results and pixels.
    local ids={scenes[1].id,scenes[2].id};scenes=nil
    if bounce then
      job.phase='rendering-bounces'
      if cameraView then require('ge/extensions/beamrt/vehicleCameraReflectionMask').render(db,ids,cameraSnapshot,work,job,gpuEndpoint)
      else require('ge/extensions/beamrt/vehicleReflectionMask').render(db,poses,ids,work,job)end
      poses=nil
    else
    local frames
    if detail then
      frames={frame(db,poses,128,96,db.carBounds[1],true),frame(db,poses,128,96,db.carBounds[2],true)}
    else frames={frame(db,poses,job.width,job.height)}end
    job.frames=frames;poses=nil
    job.phase='rendering'
    for y=0,job.height-1 do for x=0,job.width-1 do
      local panel=detail and math.floor(x/job.panelWidth)+1 or 1
      local f=frames[panel]
      local exclude=detail and ids[3-panel] or nil
      local hit=bvh.trace(db,origin(f,x%job.panelWidth,y),f.direction,f.far,exclude,work,job.trace)
      local pixel={12,16,23}
      if hit then
        if detail then
          assert(hit.carIndex==panel,'Isolated normal panel hit the wrong car')
          for j=1,3 do pixel[j]=math.max(0,math.min(255,math.floor((hit.normal[j]+1)*127.5+.5)))end
        else
          local shade=.35+.65*(1-hit.distance/f.far)
          for j=1,3 do pixel[j]=math.floor(palette[hit.carIndex][j]*shade+.5)end
        end
        pixel.vehicleId=hit.vehicleId;pixel.distance=hit.distance
        pixel.frontFacing=hit.frontFacing
        if hit.frontFacing then job.frontFacePixels=job.frontFacePixels+1 else job.backFacePixels=job.backFacePixels+1 end
        job.hits[hit.carIndex]=job.hits[hit.carIndex]+1
      end
      job.pixels[#job.pixels+1]=pixel;job.pixelsRendered=job.pixelsRendered+1;work()
    end end
    end
    if cameraView then assert(job.hits[1]+job.hits[2]>0,'Camera did not sample either captured car; point at a visible panel and recapture')
    else assert(job.hits[1]>0 and job.hits[2]>0,'Fixed view did not sample both cars; check separation and geometry')end
    if surface then
      job.phase='checking-materials'
      local ok,why=require('ge/extensions/beamrt/vehicleMaterialSnapshot').matches(job.materialSnapshot)
      assert(ok,why);job.materialSnapshotMatched=true
    end
    db=nil;job.phase='complete'
  end)
  return job
end
function M.advance(job,dt)
  if job.phase=='complete' or job.phase=='cancelled' then return end
  assert(finite(dt) and dt>=0,'Invalid image frame delta')
  job.elapsed=job.elapsed+dt;assert(job.elapsed<180,'CPU BVH/image diagnostic timed out')
  local ok,err=coroutine.resume(job.co);assert(ok,tostring(err))
  if coroutine.status(job.co)=='dead' then job.co=nil end
end
function M.cancel(job)
  if not job then return end
  if job.gpuSocket then pcall(job.gpuSocket.close,job.gpuSocket);job.gpuSocket=nil end
  job.co=nil;job.pixels={};job.controls.scenes=nil;job.controls.scratch=nil;job.materialSnapshot=nil;job.gpuImageExpected=nil;job.gpuImageWitnesses=nil
  job.phase='cancelled'
end
function M.status(job)
  if not job then return {phase='idle',cpuReferenceOnly=true}end
  local surface=job.profile=='camera-material'
  local gpuImage=job.profile=='camera-gpu-image'
  local cameraView=job.profile=='camera-bounce' or surface or job.profile=='camera-gpu' or gpuImage
  local bounce=job.profile=='bounce' or cameraView
  local out={phase=job.phase,profile=job.profile,width=job.width,height=job.height,pixelsRendered=job.pixelsRendered,
    panelWidth=job.panelWidth,viewCount=(surface or gpuImage) and 4 or (cameraView and 2 or (job.profile=='bounce' and 4 or (job.profile=='normals' and 2 or 1))),
    oneBounceGeometryMask=bounce,primaryReceiverIsolated=job.profile=='bounce',
    primaryFullPair=cameraView,cameraProjectionValidated=job.cameraSnapshot and job.cameraSnapshot.projectionValidated or false,
    secondaryFullPair=bounce,receiverSelfHitsRetained=bounce,
    idealMirrorAssumption=bounce,bounceOriginOffsetMetres=bounce and .01 or nil,
    segmentEndpointExclusionMetres=.08,
    isolatedCars=job.profile=='normals',geometricNormals=job.profile=='normals',normalFrame='world',
    normalEncoding=job.profile=='normals' and 'RGB=0.5*(signed geometric normal+1)' or 'not displayed',
    authoredNormalsCaptured=false,windingVerified=false,frontFacePixels=job.frontFacePixels,backFacePixels=job.backFacePixels,
    totalPixels=job.width*job.height,trianglesCopied=job.build.copied or 0,totalTriangles=job.build.total or 0,
    nodes=job.build.nodes or 0,allocatedBVHBytes=job.build.bytes or 0,workOperations=job.workOperations,
    bvhNodeTests=job.trace.nodeTests,bvhTriangleTests=job.trace.triangleTests,
    referenceTriangleTests=job.controls.tests,hitsA=job.hits[1],hitsB=job.hits[2],elapsedSeconds=job.elapsed,
    acceleratorMatchesReference=job.acceleratorMatchesReference,cpuReferenceOnly=true,
    fullPrimitiveReferences=true,fixedOrthographicView=not cameraView,gameplayCameraUsed=cameraView,
    alphaTexturesSampled=false,opaqueVisibilityVerified=false,sceneComplete=false,
    gpuExecutionVerified=false,materialShadingVerified=false,offscreenReflectionTestPassed=false}
  if surface then
    local s=job.materialSnapshot
    out.materialFactorPreview=true;out.materialSnapshotMatched=job.materialSnapshotMatched or false
    out.materialColorFormatRevision=2
    out.textureColorsSampled=false;out.paintPaletteSampled=false;out.roughnessApplied=false
    out.receiverBRDFApplied=false;out.sceneLightingUsed=false
    out.factorLighting='display-space layer-zero factors * (0.2 + 0.8*abs(dot(faceNormal,{0.36,-0.48,0.8})))'
    if s then
      out.materials={requested=#s.names,resolved=s.resolved,factors=s.factors,unknown=s.unknown,
        textureDependent=s.textureDependent,instanceDependent=s.instanceDependent,layered=s.layered,layer=0}
    end
  end
  if job.bounce then for key,value in pairs(job.bounce)do out[key]=detached(value)end end
  if job.gpuProbe then out.gpuProbe=detached(job.gpuProbe)end
  if job.gpuImage then out.gpuImage=detached(job.gpuImage)end
  if job.cameraSnapshot then
    local c=job.cameraSnapshot
    out.frozenCamera={view=c.view,viewportWidth=c.viewportWidth,viewportHeight=c.viewportHeight,
      nativeRayChecks=c.nativeRayChecks,maxNativeDirectionError=c.maxNativeDirectionError,
      near=c.near,far=c.far,left=c.left,right=c.rightEdge,top=c.top,bottom=c.bottom,primaryDistanceCap=1000}
    out.frozenCamera.position={c.position[1],c.position[2],c.position[3]}
    out.frozenCamera.rightAxis={c.right[1],c.right[2],c.right[3]}
    out.frozenCamera.forward={c.forward[1],c.forward[2],c.forward[3]}
    out.frozenCamera.up={c.up[1],c.up[2],c.up[3]}
    out.cameraSnapshotFrozen=true;out.cameraMotionRequiresRecapture=true
  end
  return out
end
function M.materialStatus(job)
  return require('ge/extensions/beamrt/vehicleMaterialSnapshot').status(job and job.materialSnapshot)
end
local function le(value,bytes)
  local out={};for i=1,bytes do out[i]=string.char(value%256);value=math.floor(value/256)end
  return table.concat(out)
end
function M.bitmap(job)
  assert(job.phase=='complete','Image not complete')
  local rowBytes=math.ceil(job.width*3/4)*4;local payload=rowBytes*job.height
  local result={'BM',le(54+payload,4),le(0,4),le(54,4),le(40,4),le(job.width,4),le(job.height,4),
    le(1,2),le(24,2),le(0,4),le(payload,4),le(0,4),le(0,4),le(0,4),le(0,4)}
  for y=job.height-1,0,-1 do
    local row={}
    for x=0,job.width-1 do local p=job.pixels[y*job.width+x+1];row[#row+1]=string.char(p[3],p[2],p[1])end
    row[#row+1]=string.rep('\0',rowBytes-job.width*3);result[#result+1]=table.concat(row)
  end
  return table.concat(result)
end
function M.draw(job)
  local im=assert(ui_imgui,'ui_imgui unavailable')
  im.SetNextWindowSize(im.ImVec2(550,420),im.Cond_FirstUseEver)
  local visible=im.Begin(job and job.profile=='camera-gpu-image' and 'BeamRT CPU/GPU geometry image - NOT shaded reflections'
    or 'BeamRT CPU geometry image - NOT shaded reflections')
  local ok,err=pcall(function()
    if not visible then return end
    if job and job.phase=='cancelled' and job.failureReason then
      im.TextUnformatted('Diagnostic stopped before completion.')
      if type(im.TextWrapped)=='function'then im.TextWrapped('%s',job.failureReason)
      else im.TextUnformatted(job.failureReason)end
      im.TextUnformatted('No successful result was published. Check getGpuStatus() / getImageStatus().')
      return
    end
    if not job or job.phase~='complete' then
      local s=M.status(job)
      im.TextUnformatted('CPU diagnostic: '..(job and s.phase or 'acquiring'))
      im.TextUnformatted(string.format('Copied %d / %d triangle references; %d BVH nodes',
        s.trianglesCopied or 0,s.totalTriangles or 0,s.nodes or 0))
      im.TextUnformatted(string.format('Pixels %d / %d; reference triangle tests %d',
        s.pixelsRendered or 0,s.totalPixels or M.width*M.height,s.referenceTriangleTests or 0))
      if job and job.bounce then
        im.TextUnformatted(string.format('Other-car bounces A/B: %d / %d; bounce reference checks: %d',
          job.bounce.otherHitsA,job.bounce.otherHitsB,job.bounce.bounceReferenceTriangleTests))
      end
      if job and job.gpuProbe then
        local g=job.gpuProbe
        im.TextUnformatted(string.format('Isolated GPU: %s | triangles %d / %d | sent %d bytes',
          g.phase,g.trianglesPacked,g.triangles,g.bytesSent))
      end
      if job and job.gpuImage then
        local g=job.gpuImage
        im.TextUnformatted(string.format('GPU BVH image: %s | nodes %d / %d | sent %d bytes',g.phase,g.nodesPacked,g.nodes,g.bytesSent))
      end
      im.TextUnformatted('Keep both cars and physics paused. Cancellation drops unfinished data.')
      return
    end
    local surface=job.profile=='camera-material'
    local gpuImage=job.profile=='camera-gpu-image'
    im.TextUnformatted(gpuImage and 'LEFT CPU / RIGHT GPU | TOP full pair / BOTTOM source excluded'
      or (surface and 'LEFT hit identity / RIGHT reflected material factors + diagnostic light'
      or ((job.profile=='camera-bounce' or job.profile=='camera-gpu') and 'Frozen main camera: TOP full pair / BOTTOM source excluded'
      or (job.profile=='bounce' and 'Top A / B bounces; bottom repeats with source excluded'
      or (job.profile=='normals' and 'Isolated close-ups: A left / B right / signed WORLD face normals'
      or 'Fixed geometry view: cyan A / magenta B / dark miss')))))
    im.TextUnformatted(surface and 'TOP full pair / BOTTOM source excluded. Purple = unknown material.'
      or ((job.profile=='bounce' or job.profile=='camera-bounce' or job.profile=='camera-gpu' or gpuImage) and 'Green=other, orange=self, slate=miss. Opacity UNKNOWN.'
      or (job.profile=='normals' and 'RGB = XYZ face direction. Winding / opacity UNKNOWN.'
      or 'Brightness = geometric depth. Glass opacity UNKNOWN.')))
    if surface then im.TextUnformatted('Textures / paint / opacity / scene lighting absent; all receivers ideal mirrors.')end
    if job.gpuProbe then
      local g=job.gpuProbe
      im.TextUnformatted(string.format('Isolated GPU ray checks: %d / %d matched | %s',g.matched,g.rays,g.phase))
      im.TextUnformatted('CPU mask shown; separate GPU readback checked. No game-frame GPU effect yet.')
    end
    if job.gpuImage then
      local g=job.gpuImage
      im.TextUnformatted(string.format('GPU image: %d / %d pixels agree | %d invalid | %s',g.pixelsMatched,g.pixels,g.invalidPixels,g.phase))
      im.TextUnformatted(string.format('GPU offscreen hits: %d | material shading / native-frame composition pending',g.offscreenHits))
      if g.gpuLinearRecheckRequired then im.TextUnformatted(string.format('Full-scan GPU recheck: %d / %d agree; strict CPU mismatch retained',g.gpuLinearRecheckMatched,g.gpuLinearRecheckSamples))end
    end
    if job.bounce and job.bounce.offscreenSourceBounds then
      local b=job.bounce
      im.TextUnformatted(string.format('Whole-source offscreen hits: %d | geometry controls: %s',
        b.offscreenSourceHitsA+b.offscreenSourceHitsB,b.offscreenGeometryControlsPassed and 'PASS' or 'not passed'))
      local a,c=b.offscreenSourceBounds[1],b.offscreenSourceBounds[2]
      im.TextUnformatted('Bounds A: '..(a.outside and 'outside ('..a.plane..')' or 'not certified outside')
        ..' | B: '..(c.outside and 'outside ('..c.plane..')' or 'not certified outside'))
    end
    local p=im.GetCursorScreenPos();local draw=im.GetWindowDrawList()
    local scale=math.min((job.profile=='bounce' or job.profile=='camera-bounce' or job.profile=='camera-gpu' or surface or gpuImage) and 2 or 8,math.max(1,im.GetContentRegionAvailWidth()/job.width))
    if job.bounce and job.bounce.offscreenSourceBounds then
      -- Keep the new evidence labels from pushing a control row below the
      -- visible panel. Older UI wrappers without this accessor retain scroll.
      if type(im.GetContentRegionAvail)=='function' then
        local avail=im.GetContentRegionAvail()
        if avail and type(avail.y)=='number' then scale=math.min(scale,math.max(1,(avail.y-24)/job.height))end
      end
    end
    for y=0,job.height-1 do
      local x=0
      while x<job.width do
        local a=job.pixels[y*job.width+x+1];local finish=x+1
        while finish<job.width do
          local b=job.pixels[y*job.width+finish+1]
          if a[1]~=b[1] or a[2]~=b[2] or a[3]~=b[3]then break end;finish=finish+1
        end
        local color=a[1]+a[2]*256+a[3]*65536+4278190080
        im.ImDrawList_AddRectFilled(draw,im.ImVec2(p.x+x*scale,p.y+y*scale),
          im.ImVec2(p.x+finish*scale,p.y+(y+1)*scale),color)
        x=finish
      end
    end
    im.Dummy(im.ImVec2(job.width*scale,job.height*scale))
    im.TextUnformatted('Paused diagnostic only; stop/reset invalidates this image.')
  end)
  im.End();assert(ok,tostring(err))
end
return M
