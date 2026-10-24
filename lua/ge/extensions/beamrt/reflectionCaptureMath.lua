-- Pure camera math: no engine objects, world mutations or assumed target data.
local M = {}
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function vector(v)
  if not v then error('Missing camera vector') end
  local r={v.x or v[1],v.y or v[2],v.z or v[3]}
  for i=1,3 do if not finite(r[i])then error('Nonfinite camera vector')end end
  return r
end
local function dot(a,b)return a[1]*b[1]+a[2]*b[2]+a[3]*b[3]end
local function scale(a,s)return {a[1]*s,a[2]*s,a[3]*s}end
local function cross(a,b)return {a[2]*b[3]-a[3]*b[2],a[3]*b[1]-a[1]*b[3],a[1]*b[2]-a[2]*b[1]}end
function M.frame(camera,height,mode)
  local ok,result=pcall(function()
    if mode~='mirror' and mode~='rear' then error('Capture mode must be mirror or rear')end
    local e,r,f,u=vector(camera.eye),vector(camera.right),vector(camera.forward),vector(camera.up)
    for _,a in ipairs({r,f,u})do if math.abs(dot(a,a)-1)>.02 then error('Camera basis is not unit length')end end
    if math.abs(dot(r,f))>.02 or math.abs(dot(r,u))>.02 or math.abs(dot(f,u))>.02 or dot(cross(r,f),u)<.98 then
      error('Camera basis is not right-handed orthonormal')
    end
    if not finite(camera.fov)or camera.fov<5 or camera.fov>170 then error('Invalid capture FOV')end
    if mode=='mirror' then
      if not finite(height)then error('A finite water-plane height is required')end
      if e[3]<=height+.01 then error('Mirror probe requires an above-water camera')end
      e={e[1],e[2],2*height-e[3]}
      -- Reflected basis alone is left-handed. Negate the reflected right axis
      -- to form a real camera rotation; project with THIS basis, not a second X flip.
      r={-r[1],-r[2],r[3]};f={f[1],f[2],-f[3]};u={u[1],u[2],-u[3]}
    else r=scale(r,-1);f=scale(f,-1)end
    return {eye=e,right=r,forward=f,up=u,fov=camera.fov,height=height,mode=mode}
  end)
  if not ok then return nil,tostring(result)end
  return result
end
function M.project(frame,point,aspect)
  local ok,result=pcall(function()
    if not finite(aspect)or aspect<=0 then error('Invalid capture aspect')end
    local p=vector(point)
    for i=1,3 do p[i]=p[i]-frame.eye[i]end
    local z=dot(p,frame.forward)
    if z<=.001 then return nil end
    local tangent=math.tan(math.rad(frame.fov)*.5)
    local uv={.5+.5*dot(p,frame.right)/(z*tangent*aspect),.5-.5*dot(p,frame.up)/(z*tangent)}
    if not finite(z)or not finite(uv[1])or not finite(uv[2])then error('Invalid capture projection')end
    if uv[1]<0 or uv[1]>1 or uv[2]<0 or uv[2]>1 then return nil end
    return {u=uv[1],v=uv[2],depth=z}
  end)
  if not ok then return nil,tostring(result)end
  return result
end
return M
