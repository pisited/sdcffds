-- Transient comparisons, not quality presets or saved gameplay settings.
-- More work may recover screen-space hits; gain never makes a hit more valid.
local M = {}
local profiles = {
  normal = {label = "Normal", gain = 1, lookups = 0, reach = 0, roughness = 0,
    description = "Unmodified BeamRT tuning; no lab overrides."},
  coverage = {label = "More coverage", gain = 1, lookups = 2048, reach = 64, roughness = 0.65,
    description = "Fork: 2048 traversal-depth lookup budget, 64 m reach, roughness cutoff at least 0.65. Existing validation stays on."},
  raw = {label = "Raw", gain = 1, lookups = 2048, reach = 64, roughness = 0.65, raw = true,
    description = "Same extended coverage; one moving sample, no source/spatial/history smoothing. Noise is expected."},
  punch = {label = "8x punch", gain = 8, lookups = 2048, reach = 64, roughness = 0.65,
    description = "Same extended coverage with artificial 8x display gain. Exaggerated, not more accurate."},
  settled = {label = "Settled", gain = 1, lookups = 2048, reach = 64, roughness = 0.65, settled = true,
    description = "Same extended coverage; 0.04 current-frame blend and 0.65 spatial denoise. Check motion trails and lost detail."},
}
local order = {"normal", "coverage", "raw", "punch", "settled"}
function M.resolve(name)
  if type(name) ~= "string" or not profiles[name] then return nil end
  local copy = {id = name}
  for key, value in pairs(profiles[name]) do copy[key] = value end
  return copy
end
function M.list()
  local result = {}
  for _, name in ipairs(order) do result[#result + 1] = M.resolve(name) end
  return result
end
return M
