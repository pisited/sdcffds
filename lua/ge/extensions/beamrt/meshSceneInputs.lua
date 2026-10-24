-- One channel-preserving preparation pass frees GI slot5 for full mesh data.
-- Existing history/STBN/native-noise atlas remains unchanged.
local M={}
local prefix='BeamRT_GISourcePack'
local owned={}
local function find(suffix)return scenetree.findObject(prefix..suffix) end
local function register(o,suffix)o:registerObject(prefix..suffix);owned[#owned+1]=prefix..suffix end
function M.enable()
  if not find('Fx') then
    local state=createObject('GFXStateBlockData');state.zDefined=true;state.zEnable=false;state.zWriteEnable=false
    state.blendDefined=true;state.blendEnable=false;state.samplersDefined=true
    for i=0,1 do state:setField('samplerStates',i,'SamplerClampPoint') end;register(state,'State')
    local shader=createObject('ShaderData');shader.DXVertexShaderFile='shaders/beamrt/beamrtGISourcePackP_v001.hlsl'
    shader.DXPixelShaderFile=shader.DXVertexShaderFile;shader.pixVersion=5
    shader:setField('samplerNames',0,'lightInfoTex');shader:setField('samplerNames',1,'materialSpecTex');register(shader,'Shader')
    local fx=createObject('PostEffect');fx.isEnabled=false;fx.allowReflectPass=false;fx.renderPriority=10004.5
    fx:setField('renderTime',0,'PFXAfterDiffuse');fx:setField('shader',0,prefix..'Shader');fx:setField('stateBlock',0,prefix..'State')
    fx:setField('texture',0,'#lightinfo[RT0]');fx:setField('texture',1,'#prepass[RT1]')
    fx:setField('target',0,'#BeamRT_GISourceChannels');fx:setField('targetFormat',0,'GFXFormatR32G32B32A32F')
    fx:setField('targetScale',0,'1 1');register(fx,'Fx')
    rawset(_G,prefix..'FxCallbacks',{onEnabled=function()return true end})
  end
  find('Fx'):enable();return true
end
function M.disable()local fx=find('Fx');if fx then fx:disable() end;return true end
function M.release()
  M.disable();for i=#owned,1,-1 do local o=scenetree.findObject(owned[i]);if o then o:delete() end end
  owned={};rawset(_G,prefix..'FxCallbacks',nil)
end
return M
