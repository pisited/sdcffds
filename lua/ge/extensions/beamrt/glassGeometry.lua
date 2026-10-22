-- Read-only exterior window snapshot. No name-only material or geometry overrides.
local M={maxTriangles=4096,maxMaterials=3,width=256}
local provider=require('ge/extensions/beamrt/providers/vehicleProvider')
local function finite(n)return type(n)=='number'and n==n and math.abs(n)<math.huge end
local function vector(v)
  local a={v.x or v[1],v.y or v[2],v.z or v[3]}
  for i=1,3 do assert(finite(a[i]),'Invalid vehicle vector')end;return a
end
local function field(o,key)
  local value=o:getField(key,0);return value==nil and ''or tostring(value)
end
local function truth(s)return s=='1'or s=='true'end
local function exterior(name)
  if type(name)~='string'then return false end
  local n=name:lower()
  for _,word in ipairs({'light','lamp','beacon','lens','mirror','_int','_dmg','_on'})do
    if n:find(word,1,true)then return false end
  end
  return n:match('_glass$')or n:match('_glass_tint$')or n:match('_windshield$')or n:match('_windshield_tint$')
end
local materialFields={'mapTo','version','translucent','alphaTest','castShadows','activeLayers',
  'opacityMap','opacityFactor','opacityMapUseUV','opacityDetailMap','instanceOpacity','emissive',
  'baseColorFactor','diffuseColor','translucentBlendOp'}
local function signature(o)
  local values={o:getFilename()}
  for _,key in ipairs(materialFields)do values[#values+1]=field(o,key)end
  return table.concat(values,'|')
end
local function material(name)
  if not exterior(name)then return end
  local o=scenetree.findObject(name)
  if not o then return end
  local class=o.___type
  if class and class~=''then if class~='class<Material>'then return end
  elseif o:getClassName()~='Material'then return end
  local path=tostring(o:getFilename()):gsub('\\','/'):lower()
  if not ('/'..path):find('/vehicles/',1,true)or field(o,'mapTo')~=name then return end
  if tonumber(field(o,'version'))~=1.5 or not truth(field(o,'translucent'))
    or truth(field(o,'alphaTest'))or truth(field(o,'castShadows'))then return end
  local layers=field(o,'activeLayers');if layers~=''and tonumber(layers)~=1 then return end
  if truth(field(o,'emissive'))or truth(field(o,'instanceOpacity'))then return end
  if field(o,'opacityDetailMap')~=''then return end
  local uv=field(o,'opacityMapUseUV');if uv~=''and uv~='0'then return end
  local map=field(o,'opacityMap'):gsub('\\','/')
  if map==''or map:find('..',1,true)then return end
  if map:sub(1,1)~='/'then map='/'..map end
  if not map:match('^/vehicles/')then return end
  local available=FS:fileExists(map)or FS:fileExists(map:gsub('%.png$','.dds'))
  if not available then return end
  local factor=field(o,'opacityFactor');factor=factor==''and 1 or tonumber(factor)
  if not finite(factor)or factor<0 or factor>1 then return end
  local tint=field(o,'baseColorFactor')
  local components={};for n in tint:gmatch('[-+%d.eE]+')do components[#components+1]=tonumber(n)end
  if #components==4 then
    if not finite(components[4])or components[4]<0 or components[4]>1 then return end
    factor=factor*components[4]
  end
  return {name=name,object=o,path=map,factor=factor,signature=signature(o)}
end
function M.pose(vehicle)
  local box=vehicle:getSpawnWorldOOBB()
  local p={position=vector(vehicle:getPosition()),center=vector(box:getCenter()),
    half=vector(box:getHalfExtents()),axes={}}
  for i=1,3 do
    p.axes[i]=vector(box:getAxis(i-1));assert(p.half[i]>.01 and p.half[i]<60,'Invalid vehicle bounds')
    local a=p.axes[i];assert(math.abs(a[1]^2+a[2]^2+a[3]^2-1)<.02,'Invalid vehicle basis')
  end
  return p
end
function M.samePose(a,b)
  for _,key in ipairs({'position','center','half'})do
    for i=1,3 do if math.abs(a[key][i]-b[key][i])>.002 then return false end end
  end
  for i=1,3 do for j=1,3 do if math.abs(a.axes[i][j]-b.axes[i][j])>.0002 then return false end end end
  return true
end
local function inside(v,pose)
  for i=1,3 do
    local a=pose.axes[i];local d=0
    for j=1,3 do d=d+(v[j]-pose.center[j])*a[j]end
    if math.abs(d)>pose.half[i]+.3 then return false end
  end
  return true
end
local function prepare(record,vehicle)
  assert(type(record.acquisitionWarnings)=='table'and #record.acquisitionWarnings==0,'Incomplete native mesh capture; no partial windows accepted')
  assert(record.buffers.vertices and record.buffers.indices and record.buffers.uv1,'Native vertices/indices/UV0 unavailable')
  assert(record.counts.uv1==record.counts.vertices,'Native UV0/vertex count mismatch')
  local pose=M.pose(vehicle)
  local mats,byName,triangles={},{},{}
  local globalValid,relativeValid=true,true
  local function vertex(index)
    assert(finite(index)and index%1==0 and index>=0 and index<record.counts.vertices,'Bad native triangle index')
    local p={};for j=1,3 do p[j]=tonumber(record.buffers.vertices[index*3+j-1]);assert(finite(p[j]),'Nonfinite mesh position')end
    local uv={tonumber(record.buffers.uv1[index*2]),tonumber(record.buffers.uv1[index*2+1])}
    for j=1,2 do assert(finite(uv[j])and math.abs(uv[j])<=16,'Unsupported UV range')end
    local translated={};for j=1,3 do translated[j]=p[j]+pose.position[j]end
    globalValid=globalValid and inside(p,pose);relativeValid=relativeValid and inside(translated,pose)
    return {p=p,uv=uv}
  end
  for _,mesh in ipairs(record.flexmeshes)do
    for _,prim in ipairs(mesh.primitives)do
      local name=prim.materialName
      if byName[name]==nil then byName[name]=material(name)or false end
      local mat=byName[name]
      if mat then
        if not mat.index then
          assert(#mats<M.maxMaterials,'More than three exterior opacity materials; no truncation')
          mat.index=#mats;mats[#mats+1]=mat
        end
        local first,count=prim.firstIndex,prim.indexCount
        assert(finite(first)and finite(count)and first%1==0 and count%3==0 and first>=0 and count>=0
          and first+count<=record.counts.indices,'Bad native primitive range')
        assert(#triangles+count/3<=M.maxTriangles,'Exterior window triangle budget exceeded; no truncation')
        for i=first,first+count-1,3 do
          local t={mat=mat.index}
          for j=1,3 do t[j]=vertex(tonumber(record.buffers.indices[i+j-1]))end
          triangles[#triangles+1]=t
        end
      end
    end
  end
  assert(#triangles>0,'No supported exterior window triangles (including _glass_tint); inspect material/UV declarations')
  -- Shared prop meshes use their own transforms and are not guessed here.
  for _,mesh in ipairs(record.propmeshes or{})do for _,p in ipairs(mesh.primitives)do
    assert(not exterior(p.materialName),'Window prop mesh requires a separate verified transform')
  end end
  local zero=pose.position[1]^2+pose.position[2]^2+pose.position[3]^2<1e-8
  assert(globalValid~=relativeValid or zero and globalValid,'Ambiguous/unsupported GPUMesh coordinate frame; no guessed placement')
  local mode=relativeValid and not zero and 'vehicle-origin-relative' or 'world'
  local lo={math.huge,math.huge,math.huge};local hi={-math.huge,-math.huge,-math.huge}
  local uvLo={math.huge,math.huge};local uvHi={-math.huge,-math.huge}
  for _,t in ipairs(triangles)do for _,v in ipairs(t)do
    for j=1,3 do
      if mode=='vehicle-origin-relative'then v.p[j]=v.p[j]+pose.position[j]end
      lo[j]=math.min(lo[j],v.p[j]);hi[j]=math.max(hi[j],v.p[j])
    end
    for j=1,2 do uvLo[j]=math.min(uvLo[j],v.uv[j]);uvHi[j]=math.max(uvHi[j],v.uv[j])end
  end end
  local extent={};for j=1,3 do extent[j]=math.max(hi[j]-lo[j],.001)end
  local uvExtent={};for j=1,2 do uvExtent[j]=math.max(uvHi[j]-uvLo[j],.001)end
  local nodes,ordered={},{}
  local function build(list)
    local node={lo={math.huge,math.huge,math.huge},hi={-math.huge,-math.huge,-math.huge}}
    local index=#nodes;nodes[index+1]=node
    for _,t in ipairs(list)do for _,v in ipairs(t)do for j=1,3 do
      node.lo[j]=math.min(node.lo[j],v.p[j]);node.hi[j]=math.max(node.hi[j],v.p[j])
    end end end
    if #list<=8 then
      node.first=#ordered;node.count=#list
      for _,t in ipairs(list)do ordered[#ordered+1]=t end
    else
      local axis=1;for j=2,3 do if node.hi[j]-node.lo[j]>node.hi[axis]-node.lo[axis]then axis=j end end
      table.sort(list,function(a,b)return a[1].p[axis]+a[2].p[axis]+a[3].p[axis]<b[1].p[axis]+b[2].p[axis]+b[3].p[axis]end)
      local left,right={},{};local half=math.floor(#list/2)
      for i,t in ipairs(list)do if i<=half then left[#left+1]=t else right[#right+1]=t end end
      node.left=build(left);node.right=build(right)
    end
    return index
  end
  build(triangles)
  return {triangles=ordered,nodes=nodes,materials=mats,pose=pose,coordinateMode=mode,
    lo=lo,extent=extent,uvLo=uvLo,uvExtent=uvExtent,vehicle=vehicle}
end
function M.capture(vehicle,readyMesh)
  local id=vehicle:getID();local record,why=provider.capture(id,readyMesh)
  if not record then return nil,why end
  local ok,result=pcall(prepare,record,vehicle)
  -- The readback is needed only once; never retain native GPU mesh resources.
  if not readyMesh and record.mesh and record.mesh.free then pcall(record.mesh.free,record.mesh)end
  provider.invalidate(id)
  if not ok then return nil,tostring(result)end
  return result
end
function M.valid(data)
  local ok,value=pcall(function()
    if be:getPlayerVehicle(0)~=data.vehicle or not M.samePose(data.pose,M.pose(data.vehicle))then return false end
    if not simTimeAuthority.getPause()then return false end
    for _,m in ipairs(data.materials)do
      if scenetree.findObject(m.name)~=m.object or signature(m.object)~=m.signature then return false end
    end
    return true
  end)
  return ok and value==true
end
function M.texels(data,tag)
  local values={45678,#data.triangles,tag,1,#data.nodes,0,0,0}
  local function quant(n,min,extent)return math.max(0,math.min(65535,math.floor((n-min)/extent*65535+.5)))end
  for _,node in ipairs(data.nodes)do
    for j=1,3 do values[#values+1]=math.max(0,quant(node.lo[j],data.lo[j],data.extent[j])-2)end
    for j=1,3 do values[#values+1]=math.min(65535,quant(node.hi[j],data.lo[j],data.extent[j])+2)end
    values[#values+1]=node.first or node.left
    values[#values+1]=node.count and (32768+node.count)or node.right
  end
  for _,t in ipairs(data.triangles)do
    for _,v in ipairs(t)do for j=1,3 do values[#values+1]=quant(v.p[j],data.lo[j],data.extent[j])end end
    for _,v in ipairs(t)do for j=1,2 do values[#values+1]=quant(v.uv[j],data.uvLo[j],data.uvExtent[j])end end
    values[#values+1]=t.mat
  end
  return values
end
return M
