-- Read-only GPUMesh metadata versus independently acquired live JBeam props.
-- Sources: shipped util/export.lua and vehicleEditor/liveEditor/veLightsDebug.lua.
-- Does NOT transform vertices, certify a frame or assume nativeIndex == pid.
local M={}
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function field(o,k)
  local v=o[k];if type(v)=='function' then return v(o) end;return v
end
local function tuple(v,n)
  assert(v,'Missing native transform')
  local keys={'x','y','z','w'};local result={}
  for i=1,n do
    local value=v[keys[i]];if value==nil then value=v[i] end
    result[i]=tonumber(value);assert(finite(result[i]),'Invalid transform component')
  end
  return result
end
local function distance(a,b)
  local d=0;for i=1,3 do d=d+(a[i]-b[i])^2 end;return math.sqrt(d)
end
local function angle(a,b,invert)
  local dot,aa,bb=0,0,0
  for i=1,4 do
    local value=invert and i<4 and -a[i] or a[i]
    dot=dot+value*b[i];aa=aa+a[i]^2;bb=bb+b[i]^2
  end
  assert(aa>.95 and aa<1.05 and bb>.95 and bb<1.05,'Nonunit prop quaternion')
  -- q and -q denote the same rotation. This comparison normalizes roundoff;
  -- it never normalizes/applies an invalid native transform to geometry.
  return 2*math.acos(math.min(1,math.abs(dot)/math.sqrt(aa*bb)))*180/math.pi
end
function M.inspect(record,nativeMesh,vehicle,origin)
  local report={source='unique mesh name to live JBeam pid; snapshot metadata only',
    nativeProps=#record.propmeshes,metadataAvailable=0,matched=0,unmatched=0,ambiguous=0,
    invalidNative=0,liveUnavailable=0,orientationAvailable=0,orientationUnavailable=0,
    comparisonAvailable=false,propTransformsVerified=false,details={}}
  if report.nativeProps==0 then return report end
  local ok,byName=pcall(function()
    assert(core_vehicle_manager and type(core_vehicle_manager.getVehicleData)=='function',
      'Vehicle manager metadata unavailable')
    local data=core_vehicle_manager.getVehicleData(vehicle:getID())
    assert(data and data.vdata and type(data.vdata.props)=='table','JBeam prop metadata unavailable')
    local result={};local count=0
    for _,prop in pairs(data.vdata.props) do
      count=count+1;assert(count<=2048,'JBeam prop metadata budget exceeded')
      if type(prop)=='table' and type(prop.mesh)=='string' and prop.mesh~='' then
        local candidates=result[prop.mesh] or {};result[prop.mesh]=candidates
        candidates[#candidates+1]=prop.pid
        -- Missing/invalid pids must still count as candidates, never collapse
        -- an ambiguous name into a fabricated unique match.
        if prop.pid==nil then candidates[#candidates+1]=false end
      end
    end
    return result
  end)
  if not ok then report.reason=tostring(byName);return report end
  report.comparisonAvailable=true
  for _,mesh in ipairs(record.propmeshes) do
    local detail={nativeIndex=mesh.nativeIndex,meshName=mesh.meshName,propTransformVerified=false}
    report.details[#report.details+1]=detail
    local nativeOK,native=pcall(function()
      local descriptor=assert(nativeMesh:propmeshes(mesh.nativeIndex),'Native prop descriptor unavailable')
      local position=tuple(field(descriptor,'position'),3)
      local rotation=tuple(field(descriptor,'rotation'),4)
      angle(rotation,rotation,false) -- reject a zero/nonunit quaternion
      return {position=position,rotation=rotation}
    end)
    if not nativeOK then
      detail.reason=tostring(native);report.invalidNative=report.invalidNative+1
    else
      detail.nativePosition=native.position;detail.nativeRotation=native.rotation
      report.metadataAvailable=report.metadataAvailable+1
      local candidates=byName[mesh.meshName] or {}
      if #candidates==0 then
        detail.reason='No exact JBeam mesh-name match';report.unmatched=report.unmatched+1
      elseif #candidates~=1 then
        detail.reason='Ambiguous JBeam mesh-name match';report.ambiguous=report.ambiguous+1
      else
        local liveOK,live=pcall(function()
          local pid=candidates[1]
          assert(finite(pid) and pid>=0 and pid%1==0,'Invalid JBeam prop pid')
          local prop=assert(vehicle:getProp(pid),'Live prop unavailable')
          local matrix=assert(prop:getLiveTransformWorld(),'Live prop matrix unavailable')
          return {pid=pid,matrix=matrix,position=tuple(matrix:getColumn(3),3)}
        end)
        if not liveOK then
          detail.reason=tostring(live);report.liveUnavailable=report.liveUnavailable+1
        else
          detail.pid=live.pid;detail.liveRelativePosition=live.position
          local world={};for i=1,3 do world[i]=live.position[i]+origin[i] end
          -- Editor evidence establishes this live anchor convention. Test both
          -- native-position interpretations; neither becomes an accepted frame.
          detail.originRelativeTranslationErrorMetres=distance(native.position,live.position)
          detail.worldTranslationErrorMetres=distance(native.position,world)
          report.originRelativeTranslationMaxErrorMetres=math.max(
            report.originRelativeTranslationMaxErrorMetres or 0,detail.originRelativeTranslationErrorMetres)
          report.worldTranslationMaxErrorMetres=math.max(
            report.worldTranslationMaxErrorMetres or 0,detail.worldTranslationErrorMetres)
          report.matched=report.matched+1
          local rotationOK,rotation=pcall(function()
            -- The editor wraps toQuatF with quat before accessing its rotation.
            local q=tuple(quat(live.matrix:toQuatF()),4)
            return {direct=angle(native.rotation,q,false),inverse=angle(native.rotation,q,true)}
          end)
          if rotationOK then
            detail.directRotationErrorDegrees=rotation.direct;detail.inverseRotationErrorDegrees=rotation.inverse
            report.directRotationMaxErrorDegrees=math.max(report.directRotationMaxErrorDegrees or 0,rotation.direct)
            report.inverseRotationMaxErrorDegrees=math.max(report.inverseRotationMaxErrorDegrees or 0,rotation.inverse)
            report.orientationAvailable=report.orientationAvailable+1
          else
            detail.orientationReason=tostring(rotation);report.orientationUnavailable=report.orientationUnavailable+1
          end
        end
      end
    end
  end
  return report
end
function M.summary(report)
  local result={}
  for _,key in ipairs({'nativeProps','metadataAvailable','matched','unmatched','ambiguous','invalidNative',
    'liveUnavailable','orientationAvailable','orientationUnavailable','comparisonAvailable',
    'originRelativeTranslationMaxErrorMetres','worldTranslationMaxErrorMetres',
    'directRotationMaxErrorDegrees','inverseRotationMaxErrorDegrees','reason','propTransformsVerified'}) do
    result[key]=report[key]
  end
  return result
end
return M
