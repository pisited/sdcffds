-- Conservative separating-plane certificate for the AABB of ALL copied
-- triangle references. No scene queries, viewport writes or screen buffers.
local M={guardPixels=2,marginMetres=.01}
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function dot(a,b)return a[1]*b[1]+a[2]*b[2]+a[3]*b[3]end
local function combine(a,scaleA,b,scaleB)
  local n={};for j=1,3 do n[j]=a[j]*scaleA+b[j]*scaleB end;return n
end
function M.classify(snapshot,bounds)
  assert(snapshot.projectionValidated,'Validated frozen camera required')
  for j=1,3 do
    assert(finite(bounds.lo[j]) and finite(bounds.hi[j]) and bounds.lo[j]<=bounds.hi[j],
      'Invalid complete triangle bounds')
  end
  local s=snapshot
  -- Expand lateral planes by the same two-native-pixel allowance used by
  -- camera freshness. This certifies the FROZEN frustum, not a moved camera.
  local dx=math.max(.00001,(s.rightEdge-s.left)*M.guardPixels/s.viewportWidth)
  local dy=math.max(.00001,(s.top-s.bottom)*M.guardPixels/s.viewportHeight)
  local planes={
    {name='near',normal=s.forward,offset=-s.near},
    {name='far',normal=combine(s.forward,-1,s.right,0),offset=s.far},
    {name='left',normal=combine(s.right,s.near,s.forward,-(s.left-dx)),offset=0},
    {name='right',normal=combine(s.forward,s.rightEdge+dx,s.right,-s.near),offset=0},
    {name='bottom',normal=combine(s.up,s.near,s.forward,-(s.bottom-dy)),offset=0},
    {name='top',normal=combine(s.forward,s.top+dy,s.up,-s.near),offset=0}}
  local result={outside=false,scope='all captured triangle-reference bounds / frozen main frustum',
    conservative=true,guardPixels=M.guardPixels,guardNearPlaneX=dx,guardNearPlaneY=dy,
    marginMetres=M.marginMetres,planesChecked=6,cornersPerPlane=8}
  for _,plane in ipairs(planes)do
    local length=math.sqrt(dot(plane.normal,plane.normal))
    assert(finite(length) and length>0,'Invalid frustum plane')
    local maximum=-math.huge
    for corner=0,7 do
      local p={}
      for j=1,3 do
        local v=math.floor(corner/2^(j-1))%2==0 and bounds.lo[j] or bounds.hi[j]
        p[j]=v-s.position[j]
      end
      local distance=(dot(plane.normal,p)+plane.offset)/length
      assert(finite(distance),'Invalid bounds-to-frustum distance')
      maximum=math.max(maximum,distance)
    end
    -- EVERY corner must be beyond the SAME plane, with a positive margin.
    -- Merely having no corner inside the frustum is not sufficient: a large
    -- box can surround/intersect the viewport while all its corners miss it.
    local separation=-maximum
    if separation>M.marginMetres and (not result.outside or separation>result.minimumSeparationMetres)then
      result.outside=true;result.plane=plane.name;result.minimumSeparationMetres=separation
    end
  end
  return result
end
function M.capture(db,ids,snapshot)
  local result={}
  for car=1,2 do
    local c=M.classify(snapshot,db.carBounds[car]);c.vehicleId=ids[car];result[car]=c
  end
  return result
end
return M
