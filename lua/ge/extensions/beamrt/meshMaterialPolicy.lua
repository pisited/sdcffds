-- Live native declarations, not opacity guessed from missing offline JSON.
-- Alpha-tested/blended/custom/unresolved materials retain native fallback.
local M={}
local function field(object,name)
  local ok,value=pcall(object.getField,object,name,0)
  if ok and value~=nil and value~='' then return tostring(value) end
  return nil
end
local function boolean(value)
  if value=='0' or value=='false' then return false end
  if value=='1' or value=='true' then return true end
  return nil
end
local function alpha(value)
  if not value then return nil end
  local v={};for x in value:gmatch('[-+]?%d*%.?%d+[eE]?[-+]?%d*') do v[#v+1]=tonumber(x) end
  if #v==4 and v[4]==v[4] then return v[4] end
end
function M.capture(names)
  if type(names)~='table' or #names>16 then return nil,'material policy supports at most 16 identities; no truncation' end
  local result={modes={},records={},opaque=0,masked=0,blended=0,unknown=0,alphaTexturesSampled=false}
  for i,name in ipairs(names) do
    local record={name=name,mode=0,reason='material unresolved'}
    local ok,object=pcall(scenetree.findObject,name)
    if ok and object then
      local classOk,class=pcall(object.getClassName,object)
      if classOk and class=='Material' then
        local mapTo=field(object,'mapTo')
        local alphaTest=boolean(field(object,'alphaTest'))
        local translucent=boolean(field(object,'translucent'))
        local colorAlpha=alpha(field(object,'diffuseColor')) or alpha(field(object,'baseColorFactor'))
        local castShadows=boolean(field(object,'castShadows'))
        record.fields={mapTo=mapTo,alphaTest=alphaTest,translucent=translucent,colorAlpha=colorAlpha,castShadows=castShadows}
        if mapTo and mapTo~=name then record.reason='material mapTo does not match imported identity'
        elseif alphaTest==true then record.mode=2;record.reason='alpha-test texture required; native fallback'
        elseif translucent==true or colorAlpha and colorAlpha<.999 then record.mode=3;record.reason='transparency requires transmission; native fallback'
        elseif alphaTest==false and translucent==false and colorAlpha and colorAlpha>=.999 then
          record.mode=1;record.reason='live native Material declares opaque'
        else record.reason='incomplete native opacity declaration' end
      else record.reason='nonstandard Material class unsupported' end
    end
    record.shadowMode=record.fields and record.fields.castShadows==false and 0 or record.mode
    result.modes[i]=record.mode;result.records[i]=record
    local key=({'unknown','opaque','masked','blended'})[record.mode+1];result[key]=result[key]+1
  end
  for i=#names+1,16 do result.modes[i]=0 end
  local parts={};for i=1,16 do parts[i]=tostring(result.modes[i]) end
  result.key=table.concat(parts,' ')
  return result
end
return M
