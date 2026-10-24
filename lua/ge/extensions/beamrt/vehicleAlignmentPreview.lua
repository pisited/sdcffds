-- Bounded, opt-in debug wireframe. Sampled triangles are NOT tracer geometry.
-- Flex positions use the exporter-axis hypothesis. Props use the live engine
-- MatrixF point transform, NOT a guessed quaternion convention.
local M={maxTriangles=128}
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function xyz(v)
  local a={v.x or v[1],v.y or v[2],v.z or v[3]}
  for i=1,3 do assert(finite(a[i]),'Nonfinite preview transform') end
  return a
end
local function columns(matrix)
  local result={}
  for i=0,3 do result[i+1]=xyz(matrix:getColumn(i)) end
  return result
end
local function same(a,b,tolerance)
  for i=1,4 do for j=1,3 do
    if math.abs(a[i][j]-b[i][j])>tolerance then return false end
  end end
  return true
end
local function distance(a,b)
  local d=0;for i=1,3 do d=d+(a[i]-b[i])^2 end;return math.sqrt(d)
end
local function total(meshes)
  local count=0
  for _,mesh in ipairs(meshes) do for _,p in ipairs(mesh.primitives) do count=count+p.indexCount/3 end end
  return count
end
local function sample(output,meshes,sharedBuffers,count,transform,kind)
  local ranges={};local triangles=0
  for _,mesh in ipairs(meshes) do for _,p in ipairs(mesh.primitives) do
    if p.indexCount>0 then
      ranges[#ranges+1]={first=triangles,count=p.indexCount/3,offset=p.firstIndex,buffers=mesh.buffers or sharedBuffers}
      triangles=triangles+p.indexCount/3
    end
  end end
  count=math.min(count,triangles)
  local rangeIndex=1
  for k=1,count do
    local index=math.floor((k-.5)*triangles/count)
    while ranges[rangeIndex].first+ranges[rangeIndex].count<=index do rangeIndex=rangeIndex+1 end
    local range=ranges[rangeIndex];local triangle={kind=kind}
    local first=range.offset+(index-range.first)*3
    for corner=1,3 do
      local vi=tonumber(range.buffers.indices[first+corner-1])
      local p={};for j=1,3 do p[j]=tonumber(range.buffers.vertices[vi*3+j-1]) end
      triangle[corner]=transform(p)
      for j=1,3 do assert(finite(triangle[corner][j]),'Nonfinite preview vertex') end
    end
    output[#output+1]=triangle
    assert(#output<=M.maxTriangles,'Preview triangle budget exceeded')
  end
end
function M.build(record,placement,vehicle,origin,flexCandidate)
  assert(flexCandidate==true,'Exporter-axis flexmesh candidate did not pass')
  assert(#record.propmeshes<=64,'Preview cannot cover every prop within budget')
  local result={triangles={},props={},origin={origin[1],origin[2],origin[3]},
    sampledOnly=true,alignmentVerified=false,feedsRayTracer=false}
  if #record.propmeshes>0 then
    assert(placement.comparisonAvailable and placement.matched==#record.propmeshes
      and placement.orientationAvailable==#record.propmeshes,'Not every native prop matched a live transform')
    assert(placement.originRelativeTranslationMaxErrorMetres<=.01
      and placement.directRotationMaxErrorDegrees<=.1,'Native/live prop transform mismatch')
  end
  sample(result.triangles,record.flexmeshes,record.buffers,64,function(p)
    return {p[1]+origin[1],-p[3]+origin[2],p[2]+origin[3]}
  end,'flex')
  local details={}
  for _,detail in ipairs(placement.details) do details[detail.nativeIndex]=detail end
  local perProp=#record.propmeshes>0 and math.floor(64/#record.propmeshes) or 0
  for _,mesh in ipairs(record.propmeshes) do
    local detail=assert(details[mesh.nativeIndex],'Prop identity missing')
    assert(detail.meshName==mesh.meshName and detail.pid~=nil,'Prop identity changed')
    local prop=assert(vehicle:getProp(detail.pid),'Live prop removed')
    local matrix=assert(prop:getLiveTransformWorld(),'Live prop matrix unavailable')
    local basis=columns(matrix)
    assert(distance(basis[4],detail.liveRelativePosition)<=.001,'Prop moved during preview capture')
    result.props[#result.props+1]={pid=detail.pid,nativeIndex=mesh.nativeIndex,meshName=mesh.meshName,columns=basis}
    assert(total({mesh})>0,'Prop has no drawable triangle references')
    sample(result.triangles,{mesh},nil,perProp,function(p)
      -- Raw prop vertex axes -> engine-local axes, then use the same native
      -- MatrixF point operation used by BeamNG's editor, plus vehicle origin.
      local world=xyz(matrix:mulP3F(vec3(p[1],-p[3],p[2])))
      for j=1,3 do world[j]=world[j]+origin[j] end
      return world
    end,'prop')
    assert(same(basis,columns(prop:getLiveTransformWorld()),.0001),'Prop changed during vertex sampling')
  end
  return result
end
function M.validate(snapshot,vehicle)
  for _,prop in ipairs(snapshot.props) do
    local live=assert(vehicle:getProp(prop.pid),'Preview prop removed')
    assert(same(prop.columns,columns(live:getLiveTransformWorld()),.0001),
      'Preview prop transform changed; recapture pair')
  end
  return true
end
function M.draw(snapshot,carIndex)
  local flex=carIndex==1 and ColorF(.1,.9,1,1) or ColorF(1,.2,.8,1)
  local prop=carIndex==1 and ColorF(1,1,.1,1) or ColorF(1,.55,.1,1)
  for _,t in ipairs(snapshot.triangles) do
    local points={}
    for i=1,3 do points[i]=vec3(t[i][1],t[i][2],t[i][3]) end
    for i=1,3 do debugDrawer:drawLine(points[i],points[i%3+1],t.kind=='prop' and prop or flex) end
  end
end
return M
