local M = {}

local backends = {
  postfxHybrid = {
    name = "postfxHybrid",
    available = true,
    selectable = true,
    giSource = "hybrid",
    feedsRenderer = true,
    description = "Current screen-space GI plus CPU-acquired persistent surfels",
  },
  postfxScreen = {
    name = "postfxScreen",
    available = true,
    selectable = true,
    giSource = "screen",
    feedsRenderer = true,
    description = "Current screen-space-only GI path",
  },
  postfxSurfels = {
    name = "postfxSurfels",
    available = true,
    selectable = true,
    giSource = "surfels",
    feedsRenderer = true,
    description = "Current persistent-surfel-only diagnostic path",
  },
  cpuHybrid = {
    name = "cpuHybrid",
    available = false,
    selectable = false,
    feedsRenderer = false,
    description = "Engine.castRay is an acquisition helper inside postfxHybrid, not an independent selectable renderer",
  },
  dxr = {
    name = "dxr",
    available = false,
    selectable = false,
    feedsRenderer = false,
    description = "Future native D3D12 DXR backend; no public sandboxed GE-Lua route exists",
  },
}

local active = "postfxHybrid"

function M.register(name, descriptor)
  if type(name) ~= "string" or type(descriptor) ~= "table" then return false end
  descriptor.name = name
  backends[name] = descriptor
  return true
end

function M.select(name)
  local backend = backends[name]
  if not backend then return false, "unknown ray backend" end
  if not backend.available then return false, "ray backend is not available" end
  if backend.selectable == false then return false, "ray backend is not selectable" end
  active = name
  return true, backend
end

function M.getActive() return active, backends[active] end
function M.get(name) return backends[name] end
function M.list() return backends end

function M.syncFromGISource(source)
  local mapping = {hybrid = "postfxHybrid", screen = "postfxScreen", surfels = "postfxSurfels"}
  local name = mapping[source]
  if name and backends[name] then active = name; return true end
  return false
end

return M
