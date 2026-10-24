-- CPU-only double-precision BVH of every captured primitive reference.
-- No native handles, quantization, decimation, material opacity or GPU binding.
local M={maxTriangles=500000,maxBytes=128*1024*1024}
local ffi=require('ffi')
local intersect=require('ge/extensions/beamrt/geometryTriangleIntersection').segment
local vertex=require('ge/extensions/beamrt/vehicleRayProbe').vertexWorld
local function finite(n)return type(n)=='number' and n==n and math.abs(n)<math.huge end
local function integer(n,max)return finite(n) and n>=0 and n%1==0 and n<=max end
local function tick(work)if work then work()end end
local function ownedArray(value,element)
  -- LuaJIT ffi.istype considers fixed signed/unsigned int arrays compatible.
  -- Match the canonical element spelling from THIS runtime as well as the
  -- array form, rejecting pointers, nested arrays and other element types.
  local spelling=tostring(ffi.typeof(element)):sub(7,-2)
  return tostring(ffi.typeof(value)):match('^ctype<'..spelling..' %[[%d%?]+%]>$')~=nil
end
function M.build(scenes,work,stats)
  assert(type(vertex)=='function','Reload the pair controller for the shared CPU vertex conversion')
  assert(#scenes==2 and scenes[1].id~=scenes[2].id,'Exactly two distinct scenes required')
  local total,ranges=0,{}
  for car,scene in ipairs(scenes)do
    assert(integer(scene.id,2147483647) and scene.id>0,'Invalid BVH vehicle identity')
    local count=0
    for _,range in ipairs(scene.ranges)do
      assert(integer(range.first,1500000) and integer(range.count,1500000)
        and range.first%3==0 and range.count%3==0,'Invalid primitive reference range')
      count=count+range.count/3
      assert(#ranges<4096,'BVH range budget exceeded')
      ranges[#ranges+1]={vehicleId=scene.id,carIndex=car,kind=range.kind,meshName=range.meshName,
        materialName=range.materialName,nativeIndex=range.nativeIndex,primitive=range.primitive}
    end
    assert(count==scene.triangles,'Scene primitive reference count mismatch')
    total=total+count
  end
  assert(integer(total,M.maxTriangles) and total>0,'BVH triangle budget exceeded; no truncation')
  local bytes=total*212 -- vertices, order/provenance and worst-case 2N nodes
  assert(bytes<=M.maxBytes,'BVH destination byte budget exceeded')
  local db={count=total,ranges=ranges,bytes=bytes,nodeCount=1,
    carBounds={{lo={math.huge,math.huge,math.huge},hi={-math.huge,-math.huge,-math.huge}},
      {lo={math.huge,math.huge,math.huge},hi={-math.huge,-math.huge,-math.huge}}},
    vertices=ffi.new('double[?]',total*9),order=ffi.new('uint32_t[?]',total),
    range=ffi.new('uint32_t[?]',total),source=ffi.new('uint32_t[?]',total),
    bounds=ffi.new('double[?]',total*2*6),topology=ffi.new('int32_t[?]',total*2*4)}
  stats=stats or {};stats.total=total;stats.copied=0;stats.nodes=1;stats.bytes=bytes
  local ti,ri=0,0
  local p={}
  for car,scene in ipairs(scenes)do for _,range in ipairs(scene.ranges)do
    ri=ri+1
    local buffers=range.buffers
    local vertexCount,indexCount
    if type(buffers.vertices)=='cdata' then
      local size=ffi.sizeof(buffers.vertices)
      assert(size%12==0,'Expected an owned float vertex array, not a pointer')
      assert(ownedArray(buffers.vertices,'float'),
        'Expected owned float vertices, not a pointer/other element type')
      vertexCount=size/12
    end
    if type(buffers.indices)=='cdata' then
      local size=ffi.sizeof(buffers.indices)
      assert(size%4==0 and ownedArray(buffers.indices,'uint32_t'),
        'Expected owned uint32 indices, not a pointer/other element type')
      indexCount=size/4
    end
    assert(not indexCount or range.first+range.count<=indexCount,'Index array overrun')
    for first=range.first,range.first+range.count-1,3 do
      for corner=0,2 do
        local vi=tonumber(buffers.indices[first+corner])
        assert(integer(vi,(vertexCount or 500001)-1),'Invalid vertex reference')
        vertex(p,buffers,first+corner,range.basis,scene.origin)
        for j=1,3 do
          assert(finite(p[j]) and math.abs(p[j])<=1e8,'Invalid world-space BVH position')
          db.vertices[ti*9+corner*3+j-1]=p[j]
          local bounds=db.carBounds[car]
          bounds.lo[j]=math.min(bounds.lo[j],p[j]);bounds.hi[j]=math.max(bounds.hi[j],p[j])
        end
      end
      db.order[ti]=ti;db.range[ti]=ri;db.source[ti]=(first-range.first)/3
      ti=ti+1;stats.copied=ti;tick(work)
    end
  end end
  assert(ti==total,'BVH copy count mismatch')
  local tasks={{node=0,first=0,count=total,depth=0}}
  while #tasks>0 do
    local task=table.remove(tasks);local node=task.node;local bi=node*6;local top=node*4
    local lo,hi={math.huge,math.huge,math.huge},{-math.huge,-math.huge,-math.huge}
    for i=task.first,task.first+task.count-1 do
      local base=tonumber(db.order[i])*9
      for corner=0,2 do for j=1,3 do
        local v=tonumber(db.vertices[base+corner*3+j-1]);lo[j]=math.min(lo[j],v);hi[j]=math.max(hi[j],v)
      end end
      tick(work)
    end
    for j=1,3 do db.bounds[bi+j-1]=lo[j];db.bounds[bi+j+2]=hi[j]end
    db.topology[top]=-1;db.topology[top+1]=-1;db.topology[top+2]=task.first;db.topology[top+3]=task.count
    if task.count>8 and task.depth<40 then
      local axis=1;for j=2,3 do if hi[j]-lo[j]>hi[axis]-lo[axis]then axis=j end end
      local midpoint=(lo[axis]+hi[axis])*.5
      local a,b=task.first,task.first+task.count-1
      while a<=b do
        local base=tonumber(db.order[a])*9+axis-1
        local centroid=(db.vertices[base]+db.vertices[base+3]+db.vertices[base+6])/3
        if centroid<midpoint then a=a+1
        else local saved=db.order[a];db.order[a]=db.order[b];db.order[b]=saved;b=b-1 end
        tick(work)
      end
      local leftCount=a-task.first
      if leftCount==0 or leftCount==task.count then leftCount=math.floor(task.count/2)end
      local left,right=db.nodeCount,db.nodeCount+1;db.nodeCount=db.nodeCount+2
      assert(db.nodeCount<=total*2,'BVH node allocation exceeded')
      db.topology[top]=left;db.topology[top+1]=right;db.topology[top+3]=0
      tasks[#tasks+1]={node=right,first=task.first+leftCount,count=task.count-leftCount,depth=task.depth+1}
      tasks[#tasks+1]={node=left,first=task.first,count=leftCount,depth=task.depth+1}
      stats.nodes=db.nodeCount
    end
  end
  return db
end
local function box(db,node,origin,dir,far)
  local near,finish=0,far;local base=node*6
  for axis=1,3 do
    local low,high=tonumber(db.bounds[base+axis-1])-1e-6,tonumber(db.bounds[base+axis+2])+1e-6
    local d=dir[axis]
    if d==0 then if origin[axis]<low or origin[axis]>high then return false end
    else
      local a,b=(low-origin[axis])/d,(high-origin[axis])/d
      if a>b then a,b=b,a end
      near=math.max(near,a);finish=math.min(finish,b)
      if near>finish then return false end
    end
  end
  return true
end
function M.trace(db,origin,dir,far,exclude,work,stats)
  local norm=0;for j=1,3 do assert(finite(origin[j]) and finite(dir[j]),'Invalid BVH ray');norm=norm+dir[j]^2 end
  assert(math.abs(norm-1)<1e-6 and finite(far) and far>.16 and far<=1000,'Invalid normalized BVH segment')
  stats=stats or {nodeTests=0,triangleTests=0}
  stats.nodeTests=stats.nodeTests or 0;stats.triangleTests=stats.triangleTests or 0
  local stack={0};local best,bestIndex
  local tri={a={},b={},c={}}
  while #stack>0 do
    local node=table.remove(stack);stats.nodeTests=stats.nodeTests+1;tick(work)
    if box(db,node,origin,dir,best and best.distance or far-.08)then
      local top=node*4
      if db.topology[top]<0 then
        local first,count=tonumber(db.topology[top+2]),tonumber(db.topology[top+3])
        for i=first,first+count-1 do
          local index=tonumber(db.order[i]);local range=db.ranges[tonumber(db.range[index])]
          if range.vehicleId~=exclude then
            local base=index*9
            for j=1,3 do tri.a[j]=tonumber(db.vertices[base+j-1]);tri.b[j]=tonumber(db.vertices[base+j+2]);tri.c[j]=tonumber(db.vertices[base+j+5])end
            stats.triangleTests=stats.triangleTests+1;tick(work)
            -- Always use the ORIGINAL segment end. Using best.distance as far
            -- would incorrectly apply the kernel's .08m endpoint exclusion there.
            local d,u,v=intersect(origin,dir,far,tri)
            if d and (not best or d<best.distance or (d==best.distance and index<bestIndex))then
              bestIndex=index
              best={vehicleId=range.vehicleId,carIndex=range.carIndex,distance=d,u=u,v=v,
                kind=range.kind,meshName=range.meshName,materialName=range.materialName,
                nativeIndex=range.nativeIndex,primitive=range.primitive,triangleInPrimitive=tonumber(db.source[index]),
                reference=index,alphaDecision='unknown; geometry only'}
            end
          end
        end
      else
        stack[#stack+1]=tonumber(db.topology[top+1]);stack[#stack+1]=tonumber(db.topology[top])
      end
    end
  end
  if best then
    -- Face normal of the nearest WORLD-space triangle. This is not a native
    -- normal stream, interpolated shading normal or a winding repair.
    local base=best.reference*9
    local ax,ay,az=tonumber(db.vertices[base]),tonumber(db.vertices[base+1]),tonumber(db.vertices[base+2])
    local bx,by,bz=db.vertices[base+3]-ax,db.vertices[base+4]-ay,db.vertices[base+5]-az
    local cx,cy,cz=db.vertices[base+6]-ax,db.vertices[base+7]-ay,db.vertices[base+8]-az
    local x,y,z=by*cz-bz*cy,bz*cx-bx*cz,bx*cy-by*cx
    local length=math.sqrt(x*x+y*y+z*z)
    assert(finite(length) and length>0,'Degenerate nearest-hit normal')
    best.normal={x/length,y/length,z/length}
    best.frontFacing=best.normal[1]*dir[1]+best.normal[2]*dir[2]+best.normal[3]*dir[3]<0
  end
  return best
end
-- Independent linear scan over the copied world triangles, for a small number
-- of reflected-ray comparisons. No boxes/order/topology are consulted here.
function M.traceReference(db,origin,dir,far,exclude,work,stats)
  local norm=0;for j=1,3 do assert(finite(origin[j]) and finite(dir[j]),'Invalid reference ray');norm=norm+dir[j]^2 end
  assert(math.abs(norm-1)<1e-6 and finite(far) and far>.16 and far<=1000,'Invalid reference segment')
  stats=stats or {};stats.triangleTests=stats.triangleTests or 0
  local tri={a={},b={},c={}};local best
  for index=0,db.count-1 do
    local range=db.ranges[tonumber(db.range[index])]
    if range.vehicleId~=exclude then
      local base=index*9
      for j=1,3 do tri.a[j]=tonumber(db.vertices[base+j-1]);tri.b[j]=tonumber(db.vertices[base+j+2]);tri.c[j]=tonumber(db.vertices[base+j+5])end
      stats.triangleTests=stats.triangleTests+1
      local d=intersect(origin,dir,far,tri)
      if d and (not best or d<best.distance)then best={vehicleId=range.vehicleId,reference=index,distance=d}end
    end
    tick(work)
  end
  return best
end
return M
