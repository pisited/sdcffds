-- BeamRT shared experimental visibility contract for shadows and GI.
-- This module separates verified world-space triangles from incomplete
-- scene/material acquisition. No claim of full scene coverage is ever made.
local M = {name="visibility"}
local triangleStore = require("ge/extensions/beamrt/worldMeshCasters")
local boxStore = require("ge/extensions/beamrt/worldBoxCasters")
local lightProvider = require("ge/extensions/beamrt/providers/lightProvider")
local materialProvider = require("ge/extensions/beamrt/providers/materialProvider")
local staticProvider = require("ge/extensions/beamrt/providers/tsStaticProvider")
local generation = 0
local function finite(x)
  x=tonumber(x)
  if not x or x~=x or x==math.huge or x==-math.huge then return nil end
  return x
end
local function vec(v)
  if type(v)~="table" then return nil end
  local a,b,c=finite(v[1] or v.x),finite(v[2] or v.y),finite(v[3] or v.z)
  if a and b and c then return {a,b,c} end
end
local function sub(a,b) return {a[1]-b[1],a[2]-b[2],a[3]-b[3]} end
local function dot(a,b) return a[1]*b[1]+a[2]*b[2]+a[3]*b[3] end
local function cross(a,b)
  return {a[2]*b[3]-a[3]*b[2],
          a[3]*b[1]-a[1]*b[3],
          a[1]*b[2]-a[2]*b[1]}
end
-- Double-sided Moller-Trumbore along normalized finite segment [origin,target].
local function hitTriangle(origin,dir,far,tri)
  local a,b,c=tri.a,tri.b,tri.c
  local e1,e2=sub(b,a),sub(c,a)
  local p=cross(dir,e2)
  local det=dot(e1,p)
  if math.abs(det)<1e-7 then return nil end
  local inv=1/det
  local t=sub(origin,a)
  local u=dot(t,p)*inv
  if u < 0 or u > 1 then return nil end
  local q=cross(t,e1)
  local v=dot(dir,q)*inv
  if v < 0 or u+v > 1 then return nil end
  local dist=dot(e2,q)*inv
  if dist <= 0.08 or dist >= far-0.08 then return nil end
  return dist,u,v
end
local function hitBox(origin,dir,far,box)
  local near,exit=-1e30,1e30
  for i=1,3 do
    local d=dir[i]
    if math.abs(d)<1e-8 then
      if origin[i]<box.lo[i] or origin[i]>box.hi[i] then return nil end
    else
      local a=(box.lo[i]-origin[i])/d
      local b=(box.hi[i]-origin[i])/d
      near=math.max(near,math.min(a,b))
      exit=math.min(exit,math.max(a,b))
      if near>exit then return nil end
    end
  end
  if near>0.08 and near<far-0.08 and exit>near then return near end
end
local function conciseSource(tri,index)
  return {index=index,materialName=tri.materialName,
    alphaMode=tri.alphaMode or "unknown",source=tri.source}
end
function M.traceSegment(origin,target,options)
  local start,finish=vec(origin),vec(target)
  if not start or not finish then return {status="invalid",error="two world-space XYZ points required"} end
  local diff=sub(finish,start)
  local length=math.sqrt(dot(diff,diff))
  if length<=0.16 or length>1000 then
    return {status="invalid",error="segment must be between 0.16m and 1000m"}
  end
  local dir={diff[1]/length,diff[2]/length,diff[3]/length}
  local nearestOpaque,nearestUncertain=nil,nil
  local tested=0
  local triangles=triangleStore.getTriangles()
  for i,t in ipairs(triangles) do
    tested=tested+1
    local d=hitTriangle(start,dir,length,t)
    if d then
      local hit={distance=d,kind="triangle",identity=conciseSource(t,i)}
      if t.alphaMode=="opaque" then
        if not nearestOpaque or d<nearestOpaque.distance then nearestOpaque=hit end
      elseif not nearestUncertain or d<nearestUncertain.distance then
        nearestUncertain=hit
      end
    end
  end
  local optionsType=type(options)=="table" and options or {}
  -- AABBs are *possible* blockers only, never verified mesh geometry.
  if optionsType.includeApproximateBoxes then
    for i,b in ipairs(boxStore.getSlots()) do
      local d=hitBox(start,dir,length,b)
      if d and (not nearestUncertain or d<nearestUncertain.distance) then
        nearestUncertain={distance=d,kind="approximateAABB",identity={index=i,name=b.name}}
      end
    end
  end
  local evidence
  if nearestOpaque and
     (not nearestUncertain or nearestOpaque.distance<nearestUncertain.distance) then
    evidence=nearestOpaque
    evidence.status="blocked"
  elseif nearestUncertain then
    evidence=nearestUncertain
    evidence.status="possible-blocker"
  else
    evidence={status="unknown",kind="no verified intersection"}
  end
  evidence.length=length
  evidence.trianglesTested=tested
  evidence.sceneComplete=false
  evidence.unblockedIsNotVerified=true
  evidence.missingSources={"unimported static meshes","vehicles","forest",
                          "terrain","alpha textures","unobserved light sources"}
  return evidence
end
function M.getStats()
  local tris=triangleStore.getTriangles()
  local modes={opaque=0,mask=0,blend=0,unknown=0}
  for _,t in ipairs(tris) do
    local mode=t.alphaMode or "unknown"
    modes[mode]=(modes[mode] or 0)+1
  end
  local lightStats=lightProvider.getStats and lightProvider.getStats() or {}
  local materials=materialProvider.getStats and materialProvider.getStats() or {}
  local tsStats=staticProvider.getStats and staticProvider.getStats() or {}
  return {
    generation=generation,
    triangles=#tris,triangleOpacity=modes,
    boxProxies=boxStore.getStatus().count,
    lightRecords=lightStats.lights or 0,
    materialRecords=materials.materials or 0,
    staticInstances=tsStats.instances or 0,
    geometryComplete=false,materialTexturesResolved=false,
    feedsProductionGI=false,feedsProductionShadows=false,
    gpuReadyOpaqueTriangles=modes.opaque,
    segmentVisibilitySupported=true
  }
end
function M.rebuild()
  generation=generation+1
  return true,M.getStats()
end
function M.invalidate() generation=generation+1 end
return M
