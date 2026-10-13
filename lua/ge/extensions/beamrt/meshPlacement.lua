-- Native TSStatic point-basis capture. No raw MatrixF text/ordering guesses.
-- Evidence of API math is NOT evidence of visual mesh/pivot alignment.
local M={}
local function xyz(v)
  if not v then return nil end
  local ok,x,y,z=pcall(function() return v.x or v[1],v.y or v[2],v.z or v[3] end)
  if not ok then return nil end
  local result={tonumber(x),tonumber(y),tonumber(z)}
  for i=1,3 do local a=result[i];if not a or a~=a or math.abs(a)>1e10 then return nil end end
  return result
end
M.xyz=xyz
local function transformed(matrix,scale,p)
  return xyz(matrix:mulP3F(vec3(p[1]*scale[1],p[2]*scale[2],p[3]*scale[3])))
end
function M.capture(object)
  local ok,result=pcall(function()
    if object:getClassName()~='TSStatic' then error('one TSStatic is required') end
    local matrix=object:getTransform()
    local scale=xyz(object:getScale())
    if not scale then error('native scale unavailable') end
    for i=1,3 do if math.abs(scale[i])<1e-8 or math.abs(scale[i])>1000 then error('degenerate/excessive instance scale') end end
    local origin=transformed(matrix,scale,{0,0,0})
    if not origin then error('native transformed point unavailable') end
    local basis={origin=origin}
    for i,key in ipairs({'x','y','z'}) do
      local unit={0,0,0};unit[i]=1
      local p=transformed(matrix,scale,unit)
      if not p then error('native unit point unavailable') end
      basis[key]={p[1]-origin[1],p[2]-origin[2],p[3]-origin[3]}
    end
    local column={}
    for i=0,3 do column[i+1]=xyz(matrix:getColumn(i));if not column[i+1] then error('native transform column unavailable') end end
    local residual=0
    local controls={}
    for _,p in ipairs({{1.25,-2.5,3.75},{-4.5,2.25,-1.5},{0,0,0}}) do
      local native=transformed(matrix,scale,p)
      if not native then error('native control point unavailable') end
      local reconstructed=M.apply(basis,p)
      for i=1,3 do residual=math.max(residual,math.abs(native[i]-reconstructed[i])) end
      controls[#controls+1]={modelPoint=p,nativeWorldPoint=native,basisWorldPoint=reconstructed}
    end
    if residual>0.002 then error('native point basis failed affine check (>2mm)') end
    local shape=tostring(object.shapeName or object:getField('shapeName',0) or '')
    return {schema='beamrt.instance.placement.v1',objectId=object:getID(),objectName=object:getName(),
      shapePath=shape,basis=basis,nativeColumns=column,scale=scale,controls=controls,
      nativePointResidualMetres=residual,nativeBasisCaptured=true,basisIncludesInstanceScale=true,
      convention='world = MatrixF.mulP3F(engineModelPoint * getScale())',
      alignmentVerified=false,transformText=tostring(matrix)}
  end)
  if not ok then return nil,tostring(result) end
  return result
end
function M.apply(basis,p)
  local result={}
  for i=1,3 do result[i]=basis.origin[i]+basis.x[i]*p[1]+basis.y[i]*p[2]+basis.z[i]*p[3] end
  return result
end
function M.same(a,b)
  for _,key in ipairs({'origin','x','y','z'}) do
    for i=1,3 do if math.abs(a.basis[key][i]-b.basis[key][i])>0.001 then return false end end
  end
  return a.shapePath==b.shapePath
end
return M
