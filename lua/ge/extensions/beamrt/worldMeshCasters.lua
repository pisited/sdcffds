-- World-space triangle casters for BeamRT's opt-in shadow experiment.
-- Triangles are real planar facets, not a large axis-aligned proxy.
-- The small fixed budget avoids silently dropping or decimating mesh geometry.
local M = {}
local triangles = {}
local LIMIT = 12
local function finite(x)
  x = tonumber(x)
  if not x or x ~= x or x == math.huge or x == -math.huge or math.abs(x) > 10000000 then return nil end
  return x
end
local function vec3(x,y,z)
  local v = {finite(x), finite(y), finite(z)}
  if not v[1] or not v[2] or not v[3] then return nil end
  return v
end
local function areaSq(a,b,c)
  local ux,uy,uz = b[1]-a[1],b[2]-a[2],b[3]-a[3]
  local vx,vy,vz = c[1]-a[1],c[2]-a[2],c[3]-a[3]
  local x,y,z = uy*vz-uz*vy, uz*vx-ux*vz, ux*vy-uy*vx
  return x*x+y*y+z*z
end
local function validate(a,b,c)
  if not (a and b and c) then return false, "vertex coordinates must be finite" end
  if areaSq(a,b,c) < 0.00000001 then return false, "triangle has near-zero area" end
  return true
end
function M.clear() triangles = {}; return true end
function M.getStatus()
  return {count = #triangles, limit = LIMIT, screenIndependent = true,
          modelType = "world-space triangles", automaticMeshExtraction = false}
end
function M.getTriangles()
  local copy = {}
  for i,t in ipairs(triangles) do
    copy[i] = {a={unpack(t.a)},b={unpack(t.b)},c={unpack(t.c)}}
  end
  return copy
end
function M.set(index,ax,ay,az,bx,by,bz,cx,cy,cz)
  index = finite(index)
  if not index or index % 1 ~= 0 or index < 1 or index > LIMIT then
    return false, "index must be an integer from 1 to 12"
  end
  if index > #triangles + 1 then return false, "fill triangle slots consecutively" end
  local a,b,c = vec3(ax,ay,az),vec3(bx,by,bz),vec3(cx,cy,cz)
  local ok, err = validate(a,b,c)
  if not ok then return false,err end
  triangles[index]={a=a,b=b,c=c}
  return true
end
function M.load(list)
  if type(list) ~= "table" or #list < 1 or #list > LIMIT then
    return false,"expected 1 to 12 complete world-space triangles"
  end
  local candidate={}
  for i,t in ipairs(list) do
    if type(t)~="table" or type(t.a)~="table" or
       type(t.b)~="table" or type(t.c)~="table" then
      return false, "triangle "..i.." must have a,b,c vertex arrays"
    end
    local a,b,c=vec3(t.a[1],t.a[2],t.a[3]),
                vec3(t.b[1],t.b[2],t.b[3]),
                vec3(t.c[1],t.c[2],t.c[3])
    local ok,err=validate(a,b,c)
    if not ok then return false,"triangle "..i..": "..err end
    candidate[i]={a=a,b=b,c=c}
  end
  triangles=candidate -- all-or-nothing; never leave partially loaded geometry
  return true
end
function M.loadJson(path)
  if type(path)~="string" or path=="" then return false,"supply file path" end
  if type(jsonReadFile) ~= "function" then
    return false, "jsonReadFile is unavailable in this Lua context"
  end
  local ok,content=pcall(jsonReadFile,path)
  if not ok or type(content)~="table" then
    return false,"could not read JSON triangle file: "..path
  end
  return M.load(content.triangles or content)
end
-- For GPU binding/probe ONLY: triangulates an EXISTING captured world box.
-- This is NOT actual source mesh extraction or an accuracy improvement.
function M.testFromBox(box)
  if type(box)~="table" or type(box.lo)~="table" or
     type(box.hi)~="table" then return false,"a captured box is required" end
  local lo,hi=box.lo,box.hi
  local v={
    {lo[1],lo[2],lo[3]}, {hi[1],lo[2],lo[3]},
    {hi[1],hi[2],lo[3]}, {lo[1],hi[2],lo[3]},
    {lo[1],lo[2],hi[3]}, {hi[1],lo[2],hi[3]},
    {hi[1],hi[2],hi[3]}, {lo[1],hi[2],hi[3]}
  }
  local faces={
    {1,2,3},{1,3,4}, -- bottom
    {5,7,6},{5,8,7}, -- top
    {1,5,6},{1,6,2},
    {2,6,7},{2,7,3},
    {3,7,8},{3,8,4},
    {4,8,5},{4,5,1}
  }
  local list={}
  for i,f in ipairs(faces) do
    list[i]={a=v[f[1]],b=v[f[2]],c=v[f[3]]}
  end
  return M.load(list)
end
return M
