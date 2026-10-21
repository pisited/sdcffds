-- Opt-in, read-only area-emission prototype for prepared, material-mapped meshes.
-- No guessed light positions, native light creation, material edits or textures.
local placement=require('ge/extensions/beamrt/meshPlacement')
local M={requested=false,reason='Emissive haze is off.',range=12,maxEmitters=2}
local catalogue,selected,verified=nil,{},{}
local elapsed,lastCamera=1,nil
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function canonical(s)return '/'..tostring(s or ''):gsub('\\','/'):gsub('^/+',''):lower() end
local function bool(v)if v=='1' or v=='true' or v==true then return true elseif v=='0' or v=='false' or v==false then return false end end
local function vector(s)
  local v={};for x in tostring(s):gmatch('[-+]?%d*%.?%d+[eE]?[-+]?%d*') do v[#v+1]=tonumber(x) end
  for i=1,3 do if not finite(v[i]) then return end end;return v
end
local function emission(name,expectedMap)
  local o=scenetree.findObject(name);if not o then return end
  local class=tostring(o.___type or '')
  if class~='class<Material>' and (not o.getClassName or o:getClassName()~='Material') then return end
  local function field(k)return o:getField(k,0) end
  if field('mapTo')~=name or bool(field('emissive'))~=true
    or bool(field('alphaTest'))~=false or bool(field('translucent'))~=false then return end
  if canonical(field('emissiveMap'))~=canonical(expectedMap) then return end
  local nits=tonumber(field('emissiveIntensityNits'));local color=vector(field('emissiveFactor'))
  if not finite(nits) or nits<=0 or nits>1e6 or not color then return end
  for i=1,3 do if color[i]<0 or color[i]>64 then return end;color[i]=color[i]*nits end
  return color,bool(field('doubleSided'))==true
end
local function integrity(path,descriptor)
  local key=canonical(path)
  if verified[key]~=nil then return verified[key] end
  local s=readFile(path)
  if type(s)~='string' then verified[key]=false;return false end
  s=s:gsub('\r\n','\n');if #s~=descriptor.sourceBytes then verified[key]=false;return false end
  local a,b=1,0;for i=1,#s do a=(a+s:byte(i))%65521;b=(b+a)%65521 end
  verified[key]=b*65536+a==descriptor.sourceAdler32
  return verified[key]
end
local function sample(basis,s,twoSided,color,native)
  local p={};for i=1,3 do p[i]=placement.apply(basis,s.v[i]) end
  local u,v={},{};for i=1,3 do u[i]=p[2][i]-p[1][i];v[i]=p[3][i]-p[1][i] end
  local n={u[2]*v[3]-u[3]*v[2],u[3]*v[1]-u[1]*v[3],u[1]*v[2]-u[2]*v[1]}
  local norm=math.sqrt(n[1]^2+n[2]^2+n[3]^2);if norm<1e-10 then return end
  local center={};for i=1,3 do n[i]=n[i]/norm;center[i]=(p[1][i]+p[2][i]+p[3][i])/3 end
  local weight=s.weightArea*(norm*.5)/s.triangleArea
  -- Suppress a quadrature sample already represented by a nearby same-colour
  -- native haze source. This is conservative proximity dedup, not fixture IDs.
  for _,l in ipairs(native or {}) do
    local d=0;local dot,c2,l2=0,0,0
    for i=1,3 do d=d+(center[i]-l.position[i])^2;dot=dot+color[i]*l.color[i];c2=c2+color[i]^2;l2=l2+l.color[i]^2 end
    if d<2.25 and dot>0 and dot/math.sqrt(math.max(c2*l2,1e-20))>.98 then weight=0;break end
  end
  return {position=center,normal=n,area=twoSided and -weight or weight}
end
function M.disable()
  M.requested=false;selected={};catalogue=nil;verified={};elapsed=1;lastCamera=nil
  M.reason='Emissive haze is off.';return true
end
function M.enable()M.disable();M.requested=true;M.reason='Prepared emissive geometry discovery starting.';return true end
function M.getEmitters()return selected end
function M.update(dt,native)
  if not M.requested then return end
  elapsed=elapsed+(finite(dt) and math.max(0,math.min(dt,1)) or 1/60)
  local ok,why=pcall(function()
    local c=core_camera.getPosition();local p={c.x,c.y,c.z}
    for i=1,3 do assert(finite(p[i]),'Camera unavailable') end
    local moved=not lastCamera or (p[1]-lastCamera[1])^2+(p[2]-lastCamera[2])^2+(p[3]-lastCamera[3])^2>=16
    if elapsed<.5 and not moved then return end
    elapsed=0;lastCamera=p;selected={}
    if not catalogue then catalogue=jsonReadFile('/art/beamrt/emissive/catalog.json') end
    assert(catalogue and catalogue.schema=='beamrt.emissive.quadrature.v1','Prepared emitter catalogue unavailable')
    assert(type(findObjectList)=='function' and Box3F and vec3,'TSStatic spatial query unavailable')
    local box=Box3F();box:setExtents(vec3(360,360,360));box:setCenter(vec3(p[1],p[2],p[3]))
    local hits=findObjectList(box,256,0);assert(type(hits)=='table','TSStatic query unavailable')
    local seen,candidates={},{}
    for i=1,math.min(128,#hits) do
      local good,item=pcall(function()
        local o=hits[i]
        if type(o)=='number' or type(o)=='string' then o=scenetree.findObject(o) end
        if Sim and type(Sim.upcast)=='function' then o=Sim.upcast(o) or o end
        if not o or o:getClassName()~='TSStatic' then return end
        local id=o:getID();if seen[id] then return end;seen[id]=true
        local path=tostring(o.shapeName or o:getField('shapeName',0))
        local desc=catalogue.assets[canonical(path)]
        if not desc or not integrity(path,desc) then return end
        local pose=placement.capture(o);if not pose then return end
        local group=desc.groups[1];if not group or #desc.groups~=1 or #group.samples~=4 then return end
        local color,twoSided=emission(group.material,desc.emissiveMap);if not color then return end
        local samples,center,area={},{0,0,0},0
        for j=1,4 do
          local s=sample(pose.basis,group.samples[j],twoSided,color,native);if not s then return end
          samples[j]=s;area=area+math.abs(s.area)
          for k=1,3 do center[k]=center[k]+s.position[k]/4 end
        end
        if area<=0 then return end
        local radius=M.range
        for _,s in ipairs(samples) do
          local d=0;for k=1,3 do d=d+(s.position[k]-center[k])^2 end
          radius=math.max(radius,math.sqrt(d)+M.range)
        end
        local distance=0;for k=1,3 do distance=distance+(center[k]-p[k])^2 end
        if math.sqrt(distance)-radius>=160 then return end
        return {id=id,material=group.material,samples=samples,position=center,radius=radius,
          color=color,score=math.max(color[1],color[2],color[3])*area/(1+distance)}
      end)
      if good and item then candidates[#candidates+1]=item end
    end
    table.sort(candidates,function(a,b)if a.score==b.score then return a.id<b.id end;return a.score>b.score end)
    for i=1,math.min(M.maxEmitters,#candidates) do selected[i]=candidates[i] end
    M.reason=#selected>0 and 'Prepared LED area haze: coarse quadrature; alignment, radiometry and visibility unverified.'
      or 'No matching prepared LED instances / validated live emissive materials in range. Only two Polish Roads LED assets supported.'
  end)
  if not ok then selected={};M.reason='Emissive haze unavailable: '..tostring(why) end
end
function M.getStatus()return {requested=M.requested,reason=M.reason,count=#selected,maxEmitters=M.maxEmitters,
  supportedAssets=2,shadowVisibility=false,visualAlignmentVerified=false,photometryCalibrated=false} end
return M
