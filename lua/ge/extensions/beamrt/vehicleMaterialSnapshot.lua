-- Detached, read-only native Material factors. No texture loads, native mesh
-- streams, guessed paint colors, shader changes or material object retention.
local M={}
local fields={'version','activeLayers','diffuseColor','baseColorFactor','metallicFactor','roughnessFactor',
  'clearCoatFactor','clearCoatRoughnessFactor','alphaTest','translucent','opacityFactor',
  'diffuseMap','baseColorMap','detailMap','colorPaletteMap','normalMap','roughnessMap','metallicMap',
  'opacityMap','instanceDiffuse','vertColor'}
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function components(value,count)
  if type(value)~='string' then return nil end
  local result={}
  for token in value:gmatch('[^,%s]+')do
    local n=tonumber(token)
    if not finite(n) or n<0 or n>1 then return nil end
    result[#result+1]=n
  end
  if #result==count then return result end
end
local function color(value)
  local rgba=components(value,4)
  if rgba then return rgba,'numeric-rgba'end
  local rgb=components(value,3)
  if rgb then rgb[4]=1;return rgb,'numeric-rgb'end
  -- Installed editor/api/gui.lua's getTempFloatArray4_StringString also
  -- accepts stock-color names (e.g. White, black) via getStockColor. Do not
  -- replace missing/invalid names with its white UI fallback, or mutate the
  -- possibly shared native lookup result. Numeric factors are never names.
  if type(value)~='string' or not value:match('^%a[%w_]*$') then return nil end
  local getter=rawget(_G,'getStockColor')
  if type(getter)~='function' then return nil end
  local ok,detached=pcall(function()
    local c=getter(value)
    if c==nil then return nil end
    return {c[1],c[2],c[3],c[4]}
  end)
  if not ok or not detached then return nil end
  for j=1,4 do if not finite(detached[j]) or detached[j]<0 or detached[j]>1 then return nil end end
  return detached,'native-stock-color'
end
local function flag(value)return value=='1' or value=='true'end
local function captureOne(name)
  local record={name=name,fields={},resolved=false,factorAvailable=false}
  local ok,object=pcall(function()return scenetree.findObject(name)end)
  if not ok or not object then record.reason='unresolved material identity';return record end
  local classOK,class=pcall(function()return object.___type end)
  if not classOK or class==nil then
    classOK,class=pcall(function()return object:getClassName()end)
  end
  if not classOK or (class~='class<Material>' and class~='Material')then
    record.reason='unsupported native class';return record
  end
  record.resolved=true
  for _,name in ipairs(fields)do
    -- Layer zero matches the installed material editor's getField contract.
    local read,value=pcall(function()return object:getField(name,0)end)
    if read and value~=nil then
      value=tostring(value)
      if #value<=2048 then record.fields[name]=value else record.reason='field length exceeds budget';return record end
    end
  end
  local f=record.fields
  -- The installed editor edits diffuseColor for PBR too; baseColorFactor is
  -- retained as a fallback/alias. Refuse conflicting aliases rather than guess.
  local factor,encoding=color(f.diffuseColor)
  local alias,aliasEncoding=color(f.baseColorFactor)
  if factor and alias then
    for j=1,4 do if math.abs(factor[j]-alias[j])>1e-5 then
      record.reason='conflicting color factor aliases';return record
    end end
  end
  record.color=factor or alias
  record.colorEncoding=factor and encoding or aliasEncoding
  record.factorField=factor and 'diffuseColor' or (alias and 'baseColorFactor' or nil)
  record.factorAvailable=record.color~=nil
  record.reason=record.factorAvailable and 'layer-zero factor only' or 'color factor unavailable'
  record.metallic=components(f.metallicFactor,1)
  record.roughness=components(f.roughnessFactor,1)
  record.textureDependent=false
  for _,key in ipairs({'diffuseMap','baseColorMap','detailMap','colorPaletteMap'})do
    if f[key] and f[key]~='' then record.textureDependent=true end
  end
  record.instanceDependent=flag(f.instanceDiffuse) or flag(f.vertColor)
  record.layered=tonumber(f.activeLayers)~=nil and tonumber(f.activeLayers)>1
  record.coverage=(f.alphaTest=='0' or f.alphaTest=='false') and (f.translucent=='0' or f.translucent=='false')
    and record.color and record.color[4]>=.999 and 'declared-opaque' or 'unverified'
  return record
end
function M.capture(scenes)
  local names,seen={},{}
  for _,scene in ipairs(scenes)do for _,range in ipairs(scene.ranges)do
    local name=range.materialName
    if type(name)=='string' and name~='' and not seen[name]then
      assert(#name<=192 and #names<512,'Material identity budget exceeded; no truncation')
      seen[name]=true;names[#names+1]=name
    end
  end end
  table.sort(names)
  local out={names=names,byName={},records={},resolved=0,factors=0,textureDependent=0,instanceDependent=0,
    layered=0,unknown=0,layer=0,texturesSampled=false,paintPaletteSampled=false}
  for _,name in ipairs(names)do
    local r=captureOne(name);out.records[#out.records+1]=r;out.byName[name]=r
    if r.resolved then out.resolved=out.resolved+1 end
    if r.factorAvailable then out.factors=out.factors+1 else out.unknown=out.unknown+1 end
    if r.textureDependent then out.textureDependent=out.textureDependent+1 end
    if r.instanceDependent then out.instanceDependent=out.instanceDependent+1 end
    if r.layered then out.layered=out.layered+1 end
  end
  return out
end
function M.matches(snapshot)
  for _,old in ipairs(snapshot.records)do
    local now=captureOne(old.name)
    if old.resolved~=now.resolved or old.factorAvailable~=now.factorAvailable or old.reason~=now.reason then
      return false,'Material changed: '..old.name
    end
    if old.color then for j=1,4 do
      if old.color[j]~=now.color[j]then return false,'Resolved material color changed: '..old.name end
    end end
    for _,key in ipairs(fields)do if old.fields[key]~=now.fields[key]then return false,'Material field changed: '..old.name..'.'..key end end
  end
  return true
end
function M.pixel(snapshot,hit)
  if not hit then return {58,68,82},'miss'end
  local r=snapshot.byName[hit.materialName]
  if not r or not r.factorAvailable then return {175,85,220},'unknown'end
  -- Deliberately diagnostic lighting: fixed world direction, two-sided face
  -- response and display-space factors. Not BeamNG radiance, BRDF or tonemapping.
  local n=hit.normal;local light={.36,-.48,.8}
  local shade=.2+.8*math.abs(n[1]*light[1]+n[2]*light[2]+n[3]*light[3])
  local p={}
  for j=1,3 do p[j]=math.floor(r.color[j]*shade*255+.5)end
  return p,'factor'
end
function M.status(snapshot)
  if not snapshot then return {phase='unavailable',records={}}end
  local out={phase='captured',layer=0,texturesSampled=false,paintPaletteSampled=false,records={}}
  for _,r in ipairs(snapshot.records)do
    local c=r.color
    out.records[#out.records+1]={name=r.name,resolved=r.resolved,factorAvailable=r.factorAvailable,
      factorField=r.factorField,color=c and {c[1],c[2],c[3],c[4]} or nil,
      colorEncoding=r.colorEncoding,rawDiffuseColor=r.fields.diffuseColor,rawBaseColorFactor=r.fields.baseColorFactor,
      metallic=r.metallic and r.metallic[1],roughness=r.roughness and r.roughness[1],
      textureDependent=r.textureDependent,instanceDependent=r.instanceDependent,layered=r.layered,
      coverage=r.coverage,reason=r.reason}
  end
  return out
end
return M
