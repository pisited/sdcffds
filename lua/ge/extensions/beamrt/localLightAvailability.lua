-- Availability for the current legacy hook. An exposed backend is not an
-- implemented resource connection. Keep an existing hook disableable.
local M={}
function M.resolve(status, backendExposed)
  status=type(status)=='table' and status or {}
  local enabled=status.enabled==true
  local exposed=backendExposed==true or status.clusteredBackendExposed==true
  return {enabled=enabled,canEnable=not exposed,canDisable=enabled,
    reason=exposed and 'Clustered-light integration is not connected; native lighting is retained.' or nil}
end
return M
