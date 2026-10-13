"""Execute real Lua sunlight integration controls; not GPU execution proof.

Requires lupa for local Lua5.1 fixtures. Native shader/source generation is
covered separately using only the Python standard library in CI.
"""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime

ROOT=Path(__file__).resolve().parents[2]
MOCK=r'''
package.path='lua/?.lua;'..package.path
objects={};extensions={};stale=false;events={};logs={}
function log(level,tag,message)logs[#logs+1]=message end
function setExtensionUnloadMode(...)end
function createObject(class)
  local o={fields={},consts={},enabled=false,class=class,reloads=0}
  function o:setField(name,index,value)
    self.fields[name]=self.fields[name]or{};self.fields[name][index]=value
    events[#events+1]={'field',self.name,name,index,value}
  end
  function o:getField(name,index)return self.fields[name]and self.fields[name][index]or''end
  function o:setShaderConst(name,value)self.consts[name]=value end
  function o:registerObject(name)
    self.name=name;objects[name]=self
    -- Model upstream ShaderData's cached GFXShader path contract.
    self.initialPixelSource=self.fields.DXPixelShaderFile and self.fields.DXPixelShaderFile[0]
  end
  function o:enable()self.enabled=true end
  function o:disable()self.enabled=false end
  function o:reload()
    self.reloads=self.reloads+1
    if self.failReload then self.failReload=false;error('mock reload failed')end
    if self.class=='CustomMaterial'then
      local data=objects[self:getField('shader',0)]
      self.compiledPixelSource=data and data.initialPixelSource
    end
  end
  function o:delete()objects[self.name]=nil end
  return o
end
scenetree={findObject=function(name)return objects[name]end}
local shader=createObject('ShaderData')
shader:setField('DXPixelShaderFile',0,'shaders/common/lighting/advanced/vectorLightP.hlsl')
shader:setField('DXVertexShaderFile',0,'shaders/common/lighting/advanced/farFrustumQuadV.hlsl')
shader:setField('pixVersion',0,'5')
shader:registerObject('AL_VectorLightShader')
local material=createObject('CustomMaterial')
material:setField('shader',0,'AL_VectorLightShader');material:registerObject('AL_VectorLightMaterial')
local paint=createObject('Material');paint:registerObject('paint')
scene={objectId=42,placement={},gpuData={texture='/art/beamrt/alignment/test.data.png',triangleCount=776},
  policy={opaque=1,modes={1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},records={{name='paint',mode=1}}}}
extensions.beamrt_meshBVH={
  prepareScene=function()return true,scene end,
  getSceneBinding=function()if stale then return nil,'stale geometry'end;return scene end,
  applySceneConsts=function(fx,data,enabled)fx:setShaderConst('$meshVisibilityEnabled',enabled and 1 or 0)end}
wire='materials'
extensions.beamrt_meshAlignment={getStatus=function()return{mode=wire}end,setMode=function(value)wire=value end}
manifest={schema='beamrt.native.sun.hook.v1',nativePath='shaders/common/lighting/advanced/vectorLightP.hlsl',
  shaderPath='shaders/beamrt/generated/beamrtVectorLight_ab1234.hlsl',nativeSource='native fixture',
  generatedSource='generated fixture',dependencies={['shaders/common/lighting/advanced/farFrustumQuad.h.hlsl']='header fixture'}}
files={['/'..manifest.nativePath]=manifest.nativeSource,['/'..manifest.shaderPath]=manifest.generatedSource,
  ['/shaders/common/lighting/advanced/farFrustumQuad.h.hlsl']='header fixture'}
manifest.schema='beamrt.native.sun.hook.v2';manifest.variants={}
for index,mode in ipairs({'hybrid','beamrt-only','unshadowed','split'})do
  local path=index==1 and manifest.shaderPath or('shaders/beamrt/generated/beamrtVectorLight_ab'..index..'.hlsl')
  local source=index==1 and manifest.generatedSource or(mode..' fixture')
  manifest.variants[mode]={shaderPath=path,generatedSource=source};files['/'..path]=source
end
function readFile(path)return files[path]end
function jsonReadFile(path)if manifestAvailable==false then return nil end;return manifest end
'''

class Controls(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(MOCK)
        self.module=self.lua.eval("require('ge/extensions/beamrt/meshSunShadow')")
    def obj(self,name):return self.lua.globals().objects[name]
    def test_default_off_full_resolution_pre_light_and_no_final_composer(self):
        self.assertFalse(self.module.getStatus().enabled)
        self.assertTrue(self.module.enable()[0])
        fx=self.obj('BeamRT_MeshSunTraceFx')
        self.assertTrue(fx.enabled)
        self.assertEqual(fx.fields.renderTime[0],'PFXBeforeBin')
        self.assertEqual(fx.fields.renderBin[0],'AL_LightBin')
        self.assertEqual(fx.fields.targetScale[0],'1 1')
        self.assertEqual(fx.fields.targetFormat[0],'GFXFormatR32G32B32A32F')
        self.assertEqual(fx.fields.texture[2],self.lua.globals().scene.gpuData.texture)
        self.assertFalse(fx.allowReflectPass)
        self.assertEqual(len(list(fx.fields.texture.keys())),3)
        self.assertFalse(self.module.getStatus().gpuExecutionVerified)
        self.assertEqual(self.lua.globals().wire,'off')
    def test_hook_reloads_only_selected_shader_and_material_then_restores(self):
        self.module.enable();shader=self.obj('AL_VectorLightShader');material=self.obj('AL_VectorLightMaterial')
        private=self.obj(material.fields.shader[0])
        self.assertEqual(private.fields.DXPixelShaderFile[0],self.lua.globals().manifest.shaderPath)
        self.assertEqual(private.initialPixelSource,self.lua.globals().manifest.shaderPath)
        self.assertEqual(material.compiledPixelSource,self.lua.globals().manifest.shaderPath)
        self.assertEqual(shader.fields.DXPixelShaderFile[0],self.lua.globals().manifest.nativePath)
        self.assertEqual(material.fields.sampler.beamrtMeshSunVisibility,'#BeamRT_MeshSunVisibility')
        self.assertEqual(shader.reloads,0);self.assertEqual(material.reloads,1)
        self.assertTrue(self.module.disable())
        self.assertEqual(shader.fields.DXPixelShaderFile[0],self.lua.globals().manifest.nativePath)
        self.assertEqual(material.fields.sampler.beamrtMeshSunVisibility,'')
        self.assertEqual(material.fields.shader[0],'AL_VectorLightShader')
        self.assertEqual(shader.reloads,0);self.assertEqual(material.reloads,2)
        self.assertFalse(self.obj('BeamRT_MeshSunTraceFx').enabled)
        self.assertEqual(self.lua.globals().wire,'materials')
    def test_stale_geometry_restores_native_and_no_frustum_dependency(self):
        self.module.enable();self.module.onPreRender();self.assertTrue(self.module.getStatus().enabled)
        self.lua.globals().stale=True;self.module.onPreRender()
        self.assertFalse(self.module.getStatus().enabled)
        self.assertIn('stale',self.module.getStatus().error)
        self.assertEqual(self.obj('AL_VectorLightShader').fields.DXPixelShaderFile[0],self.lua.globals().manifest.nativePath)
    def test_unsupported_source_and_missing_manifest_never_change_native_shader(self):
        self.lua.globals().files['/'+self.lua.globals().manifest.nativePath]='new installation'
        self.assertFalse(self.module.enable()[0]);self.assertIsNone(self.obj('BeamRT_MeshSunTraceFx'))
        self.lua.globals().files['/'+self.lua.globals().manifest.nativePath]='native fixture'
        self.lua.globals().manifestAvailable=False
        self.assertFalse(self.module.enable()[0]);self.assertEqual(self.obj('AL_VectorLightShader').reloads,0)
    def test_unknown_alpha_and_native_no_shadow_casting_keep_fallback(self):
        self.lua.globals().scene.policy.records[1].mode=2
        self.assertFalse(self.module.enable()[0]);self.assertEqual(self.obj('AL_VectorLightShader').reloads,0)
        self.lua.globals().scene.policy.records[1].mode=1
        self.obj('paint').setField(self.obj('paint'),'castShadows',0,'false')
        self.assertFalse(self.module.enable()[0])
        self.obj('paint').setField(self.obj('paint'),'castShadows',0,'true')
        self.assertTrue(self.module.enable()[0])
        self.assertEqual(self.obj('BeamRT_MeshSunTraceFx').consts['$meshMaterialModes0'],'1 0 0 0')
    def test_reload_failure_rolls_back_and_retry_works(self):
        self.obj('AL_VectorLightMaterial').failReload=True
        self.assertFalse(self.module.enable()[0]);self.assertFalse(self.module.getStatus().enabled)
        self.assertEqual(self.obj('AL_VectorLightShader').fields.DXPixelShaderFile[0],self.lua.globals().manifest.nativePath)
        self.assertEqual(self.obj('AL_VectorLightMaterial').fields.sampler.beamrtMeshSunVisibility,'')
        self.assertTrue(self.module.enable()[0])
    def test_other_mod_mutations_not_overwritten_on_fallback(self):
        self.module.enable()
        self.obj('AL_VectorLightMaterial').setField(self.obj('AL_VectorLightMaterial'),'shader',0,'OtherShader')
        self.obj('AL_VectorLightMaterial').setField(self.obj('AL_VectorLightMaterial'),'sampler','beamrtMeshSunVisibility','#OtherMask')
        self.module.onPreRender()
        self.assertFalse(self.module.getStatus().enabled)
        self.assertEqual(self.obj('AL_VectorLightMaterial').fields.shader[0],'OtherShader')
        self.assertEqual(self.obj('AL_VectorLightMaterial').fields.sampler.beamrtMeshSunVisibility,'#OtherMask')
    def test_mission_unload_and_missing_renderer_restore_and_delete_owned_only(self):
        self.module.enable();self.lua.globals().extensions.beamrt_meshBVH=None;self.module.onPreRender()
        self.assertFalse(self.module.getStatus().enabled)
        self.module.onExtensionUnloaded()
        self.assertIsNone(self.obj('BeamRT_MeshSunTraceFx'))
        self.assertIsNotNone(self.obj('AL_VectorLightShader'))
        self.assertIsNone(self.lua.globals().BeamRT_MeshSunTraceFxCallbacks)
    def test_live_material_changes_disable_and_mission_restore(self):
        self.module.enable();self.lua.globals().scene.policy.records[1].mode=3;self.module.onPreRender()
        self.assertFalse(self.module.getStatus().enabled)
        self.lua.globals().scene.policy.records[1].mode=1;self.module.enable()
        self.module.onClientEndMission();self.assertFalse(self.module.getStatus().enabled)
        self.module.enable();self.module.onClientStartMission();self.assertFalse(self.module.getStatus().enabled)
    def test_all_comparison_modes_switch_owned_program_and_restore_native(self):
        self.module.enable();shader=self.obj('AL_VectorLightShader')
        for mode in ('split','beamrt-only','unshadowed','hybrid'):
            self.assertTrue(self.module.setComparisonMode(mode)[0])
            material=self.obj('AL_VectorLightMaterial')
            self.assertEqual(self.obj(material.fields.shader[0]).fields.DXPixelShaderFile[0],self.lua.globals().manifest.variants[mode].shaderPath)
            self.assertEqual(material.compiledPixelSource,self.lua.globals().manifest.variants[mode].shaderPath)
            self.assertEqual(self.module.getStatus().comparisonMode,mode)
            self.assertFalse(self.module.getStatus().ambientLightingChanged)
            self.assertFalse(self.module.getStatus().localLightShadowsChanged)
            self.module.onPreRender();self.assertTrue(self.module.getStatus().enabled)
        self.module.setComparisonMode('beamrt-only');self.module.disable()
        self.assertEqual(shader.fields.DXPixelShaderFile[0],self.lua.globals().manifest.nativePath)
        self.assertEqual(self.module.getStatus().comparisonMode,'hybrid')
    def test_comparison_can_be_selected_before_activation_and_failures_restore(self):
        self.assertTrue(self.module.setComparisonMode('split'))
        self.assertTrue(self.module.enable()[0]);shader=self.obj('AL_VectorLightShader')
        material=self.obj('AL_VectorLightMaterial')
        self.assertEqual(self.obj(material.fields.shader[0]).fields.DXPixelShaderFile[0],self.lua.globals().manifest.variants.split.shaderPath)
        self.assertFalse(self.module.setComparisonMode('unknown')[0])
        material.failReload=True;self.assertFalse(self.module.setComparisonMode('unshadowed')[0])
        self.assertFalse(self.module.getStatus().enabled)
        self.assertEqual(shader.fields.DXPixelShaderFile[0],self.lua.globals().manifest.nativePath)
    def test_old_hybrid_manifest_preserved_but_missing_comparison_is_rejected(self):
        self.lua.globals().manifest.schema='beamrt.native.sun.hook.v1'
        self.lua.globals().manifest.variants=None
        self.assertTrue(self.module.enable()[0])
        self.assertFalse(self.module.setComparisonMode('split')[0])
        self.module.disable();self.assertTrue(self.module.setComparisonMode('split'))
        self.assertFalse(self.module.enable()[0]);self.assertEqual(self.obj('AL_VectorLightShader').fields.DXPixelShaderFile[0],self.lua.globals().manifest.nativePath)
    def test_private_shader_registers_native_samplers_and_keeps_original_cached_program(self):
        self.module.enable();material=self.obj('AL_VectorLightMaterial');private=self.obj(material.fields.shader[0])
        self.assertEqual(private.fields.DXVertexShaderFile[0],self.obj('AL_VectorLightShader').fields.DXVertexShaderFile[0])
        self.assertEqual(private.fields.samplerNames[14],'beamrtMeshSunVisibility')
        self.assertEqual(private.fields.samplerNames[13],'sunShadowMask')
        self.assertEqual(self.obj('AL_VectorLightShader').initialPixelSource,self.lua.globals().manifest.nativePath)
        self.module.onExtensionUnloaded()
        self.assertIsNone(self.obj(private.name));self.assertIsNotNone(self.obj('AL_VectorLightShader'))

if __name__=='__main__':unittest.main(verbosity=2)
