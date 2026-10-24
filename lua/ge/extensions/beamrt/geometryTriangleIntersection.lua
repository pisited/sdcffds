-- Shared double-sided geometric segment kernel, extracted from sceneVisibility.
-- Caller validates finite XYZ inputs and normalized direction. No alpha policy.
local M={}
function M.segment(origin,dir,far,tri)
  local a,b,c=tri.a,tri.b,tri.c
  local x1,y1,z1=b[1]-a[1],b[2]-a[2],b[3]-a[3]
  local x2,y2,z2=c[1]-a[1],c[2]-a[2],c[3]-a[3]
  local px,py,pz=dir[2]*z2-dir[3]*y2,dir[3]*x2-dir[1]*z2,dir[1]*y2-dir[2]*x2
  local det=x1*px+y1*py+z1*pz
  if math.abs(det)<1e-7 then return nil end
  local inv=1/det
  local tx,ty,tz=origin[1]-a[1],origin[2]-a[2],origin[3]-a[3]
  local u=(tx*px+ty*py+tz*pz)*inv
  if u<0 or u>1 then return nil end
  local qx,qy,qz=ty*z1-tz*y1,tz*x1-tx*z1,tx*y1-ty*x1
  local v=(dir[1]*qx+dir[2]*qy+dir[3]*qz)*inv
  if v<0 or u+v>1 then return nil end
  local distance=(x2*qx+y2*qy+z2*qz)*inv
  if distance<=.08 or distance>=far-.08 then return nil end
  return distance,u,v
end
return M
