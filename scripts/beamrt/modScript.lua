-- BeamRT v0.032 bootstrap.
-- BeamNG 0.39 discovers scripts/**/modScript.lua when mods are mounted.

local extensionName = "beamrt_main"

-- Keep the renderer extension alive across level changes. Explicitly loading it
-- also makes activation from the Mod Manager take effect immediately.
setExtensionUnloadMode(extensionName, "manual")

if not extensions.isExtensionLoaded(extensionName) then
  extensions.load(extensionName)
end
