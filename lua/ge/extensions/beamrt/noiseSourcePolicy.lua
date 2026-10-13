-- The RGB-only v094 DDS was rejected by the current engine even after the
-- previous format repairs. Do not present it as a usable sampling resource.
-- Native noise is preserved; restoring custom STBN needs a verified loader path.
local M={}
M.nativeTexture='/shaders/common/postFx/gtao/noiseBlue.png'
M.atlasAvailable=false
M.atlasReason='experimental STBN unavailable: BeamNG rejected its DDS; native noise retained'
function M.resolve(value)
  if type(value)~='string' then return nil,"blue-noise source must be 'stbn' or 'beamng'" end
  local token=string.lower(value):gsub('[%s_%-]','')
  if token=='beamng' or token=='gtao' or token=='native' then return {mode=0,name='beamng'} end
  if token=='stbn' or token=='beamrt' or token=='spatiotemporal' then return nil,M.atlasReason end
  return nil,"blue-noise source must be 'stbn' or 'beamng'"
end
function M.atlasBinding()
  -- Valid native resource in the inactive slot; the v002 pack never reads its
  -- reserved STBN bank. No DDS lookup or fabricated 1024x1024 atlas content.
  return M.nativeTexture
end
return M
