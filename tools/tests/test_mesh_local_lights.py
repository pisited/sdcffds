"""Actual Lua underground selection/material binding/lifecycle; no GPU proof."""
import unittest
from lupa.lua51 import LuaRuntime

MOCK=r'''
package.path='lua/?.lua;'..package.path
function vec3(x,y,z)return{x=x,y=y,z=z}end
function log(...)end
function setExtensionUnloadMode(...)end
objects={};events={};removed=false;controlledId=42
function createObject(class)
  assert(class~='PointLight'and class~='SpotLight','must not create or override emitters')
  local o={fields={},reloads=0,class=class}
  function o:setField(key,index,value)
    self.fields[key]=self.fields[key]or{};self.fields[key][index]=value
    events[#events+1]={self.name,key,index,value}
  end
  function o:getField(key,index)return self.fields[key]and self.fields[key][index or 0]or''end
  function o:registerObject(name)self.name=name;objects[name]=self;self.initialPixel=self:getField('DXPixelShaderFile')end
  function o:reload()self.reloads=self.reloads+1;if self.failReload then self.failReload=false;error('reload failed')end end
  function o:delete()objects[self.name]=nil end
  return o
end
for _,kind in ipairs({'Point','Spot'})do
  local shader=createObject('ShaderData')
  shader:setField('DXPixelShaderFile',0,'shaders/common/lighting/advanced/'..kind:lower()..'LightP.hlsl')
  shader:setField('DXVertexShaderFile',0,'shaders/common/lighting/advanced/convexGeometryV.hlsl')
  shader:setField('pixVersion',0,'5');shader:registerObject('AL_'..kind..'LightShader')
  local material=createObject('CustomMaterial');material:setField('shader',0,shader.name);material:registerObject('AL_'..kind..'LightMaterial')
end
local wall={___type='class<Material>',alphaTest='0',translucent='0',mapTo='wall'}
function wall:getField(key)return self[key]or''end
objects.wall=wall
function static(name,id,shape,x)
  local o={name=name,id=id,shapeName=shape,x=x}
  function o:getClassName()return'TSStatic'end
  function o:getID()return id end
  function o:getName()return name end
  function o:getField(key)return self[key]or''end
  function o:getScale()return vec3(1,1,1)end
  function o:getTransform()
    local m={};function m:mulP3F(p)return vec3(p.x+o.x,p.y,p.z)end
    function m:getColumn(i)return({vec3(1,0,0),vec3(0,1,0),vec3(0,0,1),vec3(o.x,0,0)})[i+1]end
    return m
  end
  objects[name]=o;objects[id]=o;return o
end
shape1='/levels/west_coast_usa/art/shapes/buildings/steel_factory/s_steel_factory_sewer_01.dae'
shape2='/levels/west_coast_usa/art/shapes/buildings/steel_factory/s_steel_factory_underground_02.dae'
static('section',42,shape1,0);static('other',43,shape2,99)
scenetree={findObject=function(name)if removed and(name==42 or name=='section')then return nil end;return objects[name]end,
  findClassObjects=function()return{'section','other'}end}
camera=vec3(100.5,.5,.5);core_camera={getPosition=function()return camera end}
FS={fileExists=function()return textureAvailable~=false end}
function descriptor(shape,minimum)
  return {shapePath=shape,selectedNode='visual_a1000',space='engine-model metres, Z-up',sceneNodeTransformsBaked=true,
    gpuData={schema='beamrt.bvh.rgba8.v1',texture='/art/beamrt/alignment/section.data.png',
      width=256,height=16,nodeOffset=2,nodeStride=6,triangleStride=7,nodeCount=1,triangleCount=1,triangleOffset=8,
      quantMin={minimum,0,0},quantExtent={1,1,1},materialNames={'wall'}}}
end
registry={schema='beamrt.underground.registry.v1',assets={descriptor(shape1,100),descriptor(shape2,0)}}
manifest={schema='beamrt.native.local.hooks.v1',dependencies={['shaders/beamrt/beamrtMeshLocalLight.h.hlsl']='helper'},lights={}}
files={['/shaders/beamrt/beamrtMeshLocalLight.h.hlsl']='helper'}
for _,kind in ipairs({'Point','Spot'})do
  local native='shaders/common/lighting/advanced/'..kind:lower()..'LightP.hlsl'
  local private='shaders/beamrt/generated/beamrtLocal'..kind..'_ab1234.hlsl'
  manifest.lights[kind]={nativePath=native,shaderPath=private,nativeSource=kind..' native',generatedSource=kind..' private'}
  files['/'..native]=kind..' native';files['/'..private]=kind..' private'
end
function readFile(path)return files[path]end
function jsonReadFile(path)return path:find('registry',1,true)and registry or manifest end
'''

class Local(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True);self.lua.execute(MOCK)
        self.scene=self.lua.eval("require('ge/extensions/beamrt/meshLocalScene')")
        self.module=self.lua.eval("require('ge/extensions/beamrt/meshLocalLights')")
    def obj(self,name):return self.lua.globals().objects[name]
    def tick(self,n=30):
        for _ in range(n):self.module.onPreRender()
    def test_same_underground_scene_can_feed_gi_without_installing_local_light_hooks(self):
        self.lua.globals().ClusteredShading=self.lua.table()
        data=self.scene.prepare()
        self.lua.execute("giConstants={};giEffect={setShaderConst=function(_,name,value)giConstants[name]=value end}")
        self.scene.applySceneConsts(self.lua.globals().giEffect,data,True)
        self.assertEqual(self.lua.globals().giConstants['$meshNodeCount'],1)
        self.assertEqual(self.lua.globals().giConstants['$meshVisibilityEnabled'],1)
        self.assertEqual(self.lua.globals().giConstants['$meshMaterialModes0'],'1 0 0 0')
        self.assertEqual(self.obj('AL_PointLightMaterial').fields['shader'][0],'AL_PointLightShader')
        self.assertEqual(self.obj('AL_SpotLightMaterial').fields['shader'][0],'AL_SpotLightShader')
        self.assertFalse(self.module.getStatus().enabled)
    def test_select_by_actual_mesh_bounds_not_object_origin(self):
        selected=self.scene.prepare();self.assertEqual(selected.objectId,42)
        self.assertEqual(selected.distanceToBounds,0)
        defines,count=self.scene.defines(selected)
        self.assertEqual(count,1);self.assertIn('meshQuantMin=float3(100,0,0)',defines)
        self.assertIn('meshOrigin=float3(0,0,0)',defines)
    def test_native_point_and_spot_shading_bound_with_world_constants_and_restored(self):
        self.assertTrue(self.module.enable()[0])
        for kind in ('Point','Spot'):
            material=self.obj('AL_'+kind+'LightMaterial');private=self.obj(material.fields.shader[0])
            self.assertEqual(private.fields.DXPixelShaderFile[0],self.lua.globals().manifest.lights[kind].shaderPath)
            self.assertEqual(private.fields.samplerNames[14],'meshDataTex')
            self.assertIn('meshMaterialModes0=float4(1,0,0,0)',private.fields.defines[0])
            self.assertEqual(material.fields.sampler.meshDataTex,'/art/beamrt/alignment/section.data.png')
            self.assertEqual(self.obj('AL_'+kind+'LightShader').fields.DXPixelShaderFile[0],self.lua.globals().manifest.lights[kind].nativePath)
        self.assertFalse(self.module.getStatus().gpuExecutionVerified)
        self.assertTrue(self.module.disable())
        for kind in ('Point','Spot'):
            self.assertEqual(self.obj('AL_'+kind+'LightMaterial').fields.shader[0],'AL_'+kind+'LightShader')
            self.assertEqual(self.obj('AL_'+kind+'LightMaterial').fields.sampler.meshDataTex,'')
    def test_camera_vehicle_control_and_offscreen_caster_do_not_change_binding(self):
        self.module.enable();first=self.obj('AL_SpotLightMaterial').fields.shader[0]
        self.lua.globals().controlledId=99;self.lua.globals().camera=self.lua.eval('vec3(200,0,0)')
        self.tick();self.assertTrue(self.module.getStatus().enabled)
        self.assertEqual(self.obj('AL_SpotLightMaterial').fields.shader[0],first)
        self.assertFalse(self.module.getStatus().controlledVehicleSelectionUsed)
    def test_partial_binding_failure_rolls_back_both_materials(self):
        self.obj('AL_SpotLightMaterial').failReload=True
        self.assertFalse(self.module.enable()[0]);self.assertFalse(self.module.getStatus().enabled)
        for kind in ('Point','Spot'):self.assertEqual(self.obj('AL_'+kind+'LightMaterial').fields.shader[0],'AL_'+kind+'LightShader')
    def test_stale_removed_and_material_coverage_changes_restore_native(self):
        self.module.enable();self.lua.globals().objects[42].x=2;self.tick()
        self.assertFalse(self.module.getStatus().enabled)
        self.lua.globals().objects[42].x=0;self.module.enable();self.lua.globals().objects.wall.alphaTest='1';self.tick()
        self.assertFalse(self.module.getStatus().enabled)
        self.lua.globals().objects.wall.alphaTest='0';self.module.enable();self.lua.globals().removed=True;self.tick()
        self.assertFalse(self.module.getStatus().enabled)
    def test_other_mod_mutation_is_not_overwritten(self):
        self.module.enable();point=self.obj('AL_PointLightMaterial')
        point.setField(point,'shader',0,'OtherShader');self.module.onPreRender()
        self.assertFalse(self.module.getStatus().enabled);self.assertEqual(point.fields.shader[0],'OtherShader')
    def test_missing_geometry_texture_invalid_descriptor_and_source_fail_closed(self):
        self.lua.globals().textureAvailable=False;self.assertFalse(self.module.enable()[0])
        self.lua.globals().textureAvailable=True;self.lua.globals().registry.assets[1].gpuData.nodeStride=8
        self.assertFalse(self.module.enable()[0])
        self.lua.globals().registry.assets[1].gpuData.nodeStride=6
        path='/'+self.lua.globals().manifest.lights.Point.nativePath;self.lua.globals().files[path]='changed'
        self.assertFalse(self.module.enable()[0])
        self.assertEqual(self.obj('AL_PointLightMaterial').fields.shader[0],'AL_PointLightShader')
    def test_shader_cache_reuse_and_unload_owns_no_native_objects(self):
        self.module.enable();first=self.obj('AL_PointLightMaterial').fields.shader[0]
        self.module.disable();self.module.enable()
        self.assertEqual(self.obj('AL_PointLightMaterial').fields.shader[0],first)
        self.module.onExtensionUnloaded();self.assertIsNone(self.obj(first))
        self.assertIsNotNone(self.obj('AL_PointLightShader'))
    def test_outside_prepared_scene_has_no_rendering_changes(self):
        self.lua.globals().camera=self.lua.eval('vec3(1000,0,0)')
        self.assertFalse(self.module.enable()[0])
        self.assertEqual(self.obj('AL_SpotLightMaterial').reloads,0)
    def test_native_no_shadow_material_not_guessed_opaque_and_mission_restore(self):
        self.lua.globals().objects.wall.castShadows='false';self.assertFalse(self.module.enable()[0])
        self.lua.globals().objects.wall.castShadows='true';self.module.enable();self.module.onClientEndMission()
        self.assertFalse(self.module.getStatus().enabled)
        self.module.enable();self.module.onClientStartMission();self.assertFalse(self.module.getStatus().enabled)
    def test_clustered_backend_not_falsely_enabled_and_metadata_is_read_only_bounded(self):
        self.lua.execute("ClusteredShading=setmetatable({shadowMaxCasters=64},{__index=function()error('must not invoke backend getters')end})")
        self.assertFalse(self.module.enable()[0])
        self.assertEqual(self.obj('AL_PointLightMaterial').reloads,0)
        info=self.module.getBackendInfo();self.assertTrue(info.exposed)
        self.assertTrue(any(m.name=='shadowMaxCasters'and m.kind=='number'for m in info.members.values()))
        self.assertFalse(self.module.getStatus().clusteredDispatchIntegrated)

    def test_installed_cluster_name_is_detected_and_preferred_without_getters(self):
        self.lua.execute("ClusterShading=setmetatable({shadowMaxCasters=96},{__index=function()error('no getters')end});ClusteredShading={oldAlias=true}")
        self.assertFalse(self.module.enable()[0])
        self.assertEqual(self.obj('AL_SpotLightMaterial').reloads,0)
        info=self.module.getBackendInfo()
        self.assertEqual(info.name,'ClusterShading')
        self.assertTrue(any(m.name=='shadowMaxCasters'for m in info.members.values()))
        self.assertFalse(any(m.name=='oldAlias'for m in info.members.values()))
        self.assertTrue(self.module.getStatus().clusteredBackendExposed)

    def test_exposing_cluster_backend_stops_and_restores_active_legacy_hook(self):
        self.assertTrue(self.module.enable()[0])
        self.lua.execute('ClusterShading={}')
        self.module.onPreRender()
        self.assertFalse(self.module.getStatus().enabled)
        self.assertEqual(self.obj('AL_SpotLightMaterial').fields.shader[0],'AL_SpotLightShader')

    def test_beamng_numeric_binding_metadata_is_read_without_invoking_accessors(self):
        self.lua.execute('''
          accessorCalls=0
          local function accessor()accessorCalls=accessorCalls+1;error('must not call')end
          local inherited={[1]={inheritedRead=accessor},[2]={inheritedWrite=accessor}}
          local mt={[1]={shadowMaxCasters=accessor},[2]={shadowMaxCasters=accessor},[3]=inherited}
          inherited[3]=mt -- cyclic native metadata must remain bounded
          ClusterShading=setmetatable({___type='static_class<ClusterShading>'},mt)
          mt.__index=accessor;mt.__newindex=accessor
        ''')
        info=self.module.getBackendInfo()
        names={m.name:m.kind for m in info.members.values()}
        self.assertEqual(info.schema,'beamrt.cluster.backend-metadata.v2')
        self.assertEqual(names['meta.getters.shadowMaxCasters'],'function')
        self.assertEqual(names['meta.setters.shadowMaxCasters'],'function')
        self.assertEqual(names['meta.super.getters.inheritedRead'],'function')
        self.assertEqual(self.lua.globals().accessorCalls,0)
        self.assertEqual(self.obj('AL_SpotLightMaterial').reloads,0)

    def test_numeric_binding_slots_on_the_namespace_itself_and_member_limit(self):
        self.lua.execute('''
          ClusterShading={[1]={heatmapOverlay=function()error('must not call')end}}
        ''')
        info=self.module.getBackendInfo()
        self.assertTrue(any(m.name=='getters.heatmapOverlay'for m in info.members.values()))
        self.lua.execute('for i=1,200 do ClusterShading[1]["field"..i]=function()error("must not call")end end')
        info=self.module.getBackendInfo()
        self.assertEqual(len(info.members),128)
        self.assertTrue(info.truncated)

    def test_deep_metadata_is_truncated_without_following_arbitrary_inheritance(self):
        self.lua.execute('''
          ClusterShading={};local t=ClusterShading
          for i=1,20 do t[3]={};t=t[3]end
          t[1]={hidden=function()error('must not call')end}
        ''')
        info=self.module.getBackendInfo()
        self.assertTrue(info.truncated)
        self.assertLessEqual(len(info.members),128)

if __name__=='__main__':unittest.main(verbosity=2)
