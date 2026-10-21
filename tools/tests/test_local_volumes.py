"""Actual opt-in haze controller/selection; mocks do not prove GPU appearance."""
from pathlib import Path
import re
import unittest
import test_coherent_renderer as backend
import test_nearby_lamp_shadows as lamps
import test_tuner_ui as tuner

ROOT=Path(__file__).resolve().parents[2]
MODULES=ROOT/'lua/ge/extensions/beamrt'
SOURCE=(MODULES/'localVolumes.lua').read_text()
MAIN=(MODULES/'main.lua').read_text()
LIGHTS=r'''
sampleLight={id=1,position={0,10,5},direction={0,0,-1},range=20,
 color={1,.8,.5},brightness=2,inner=.95,outer=.8}
provider={getVolumetricLights=function()return {sampleLight}end}
camera={x=0,y=0,z=0}
core_camera={getPosition=function()return camera end,getForward=function()return {x=0,y=1,z=0}end}
nativeLamp={id=1,fields={isEnabled='1',range='20',brightness='2',color='1 .8 .5',innerAngle='20',outerAngle='50'}}
function nativeLamp:getClassName()return 'SpotLight'end
function nativeLamp:getID()return self.id end
function nativeLamp:getFields()return self.fields end
function nativeLamp:getField(k,i)return self.fields[k]end
function nativeLamp:getPosition()return {x=0,y=10,z=5}end
function nativeLamp:getTransform()return {getColumn=function()return {x=0,y=0,z=-1}end}end
function nativeLamp:setField()error('Haze must not write a lamp')end
objects[1]=nativeLamp
scenetree.findClassObjects=function(class)return class=='SpotLight' and {1} or {} end
'''

class LocalVolumes(unittest.TestCase):
    def runtimes(self):
        for lua,renderer in backend.CoherentRenderer().runtimes():
            lua.execute(LIGHTS)
            module=lua.execute(SOURCE)
            lua.globals().volume=module
            yield lua,module

    def test_import_and_status_are_non_mutating_and_start_waits_for_supported_lights(self):
        for lua,api in self.runtimes():
            self.assertFalse(api.getStatus().requested)
            self.assertEqual(lua.eval('(function()local n=0;for _ in pairs(objects)do n=n+1 end;return n end)()'),2)
            lua.execute("nativeLamp.fields.isEnabled='0'")
            self.assertTrue(api.enable())
            self.assertFalse(lua.eval('objects.BeamRT_LocalVolumeFx:isEnabled()'))
            api.update(.016,lua.table())
            self.assertTrue(api.getStatus().requested)
            self.assertFalse(api.getStatus().active)
            lua.execute("nativeLamp.fields.isEnabled='1'")
            api.update(.25,lua.globals().provider)
            self.assertTrue(api.getStatus().active)
            self.assertEqual(lua.eval('objects.BeamRT_LocalVolumeFx._const["$volumeCount"]'),1)
            self.assertEqual(lua.eval('objects.BeamRT_LocalVolumeState:getField("blendSrc",0)'),'GFXBlendOne')
            self.assertEqual(lua.eval('objects.BeamRT_LocalVolumeState:getField("blendDest",0)'),'GFXBlendZero')
            self.assertFalse(lua.eval('objects.BeamRT_LocalVolumeState.blendEnable'))
            self.assertEqual(lua.eval('objects.BeamRT_LocalVolumeFx:getField("texture",0)'),'$backBuffer')
            self.assertEqual(lua.eval('objects.BeamRT_LocalVolumeFx:getField("target",0)'),'$backBuffer')
            self.assertEqual(lua.eval('objects.BeamRT_LocalVolumeFx:getField("texture",2)'),'#prepass[Depth]')
            self.assertFalse(api.getStatus().nativeShadowVisibility)
            self.assertFalse(api.getStatus().gpuExecutionVerified)
            self.assertTrue(api.disable()[0])
            self.assertIsNone(lua.globals().objects.BeamRT_LocalVolumeFx)

    def test_uploads_are_cached_zero_strength_skips_gpu_and_bad_parameters_refused(self):
        for lua,api in self.runtimes():
            api.enable();api.update(.25,lua.globals().provider)
            lua.execute('''
            uploads=0;local p=objects.BeamRT_LocalVolumeFx;local original=p.setShaderConst
            rawset(p,'setShaderConst',function(self,k,v)uploads=uploads+1;return original(self,k,v)end)
            ''')
            api.update(.25,lua.globals().provider)
            self.assertEqual(lua.globals().uploads,0)
            self.assertTrue(api.setParameter('strength',0))
            api.update(.25,lua.globals().provider)
            self.assertEqual(lua.globals().uploads,1)
            self.assertFalse(api.getStatus().active)
            for key,value in [('strength',5),('density',1),('density',float('nan')),('unknown',1)]:
                self.assertFalse(api.setParameter(key,value))
            self.assertTrue(api.setParameter('strength',1))
            api.update(.25,lua.globals().provider)
            self.assertTrue(api.getStatus().active)

    def test_rollback_retry_pass_loss_and_foreign_replacement_safety(self):
        for lua,api in self.runtimes():
            lua.execute('failCreate=true')
            self.assertFalse(api.enable()[0])
            self.assertFalse(api.getStatus().requested)
            lua.execute('failCreate=false');api.enable();api.update(.25,lua.globals().provider)
            lua.execute('failDelete=true')
            self.assertFalse(api.disable()[0])
            self.assertTrue(api.getStatus().pendingCleanup)
            self.assertFalse(api.enable()[0])
            lua.execute('failDelete=false')
            self.assertTrue(api.disable()[0])
            api.enable();api.update(.25,lua.globals().provider)
            lua.execute("createObject('PostEffect'):registerObject('BeamRT_LocalVolumeFx')")
            lua.execute('replacement=objects.BeamRT_LocalVolumeFx')
            api.update(.25,lua.globals().provider)
            self.assertFalse(api.getStatus().requested)
            self.assertTrue(lua.eval('objects.BeamRT_LocalVolumeFx==replacement'))

    def test_main_enable_capture_guard_lifecycle_and_ui_are_explicit(self):
        for lua,api in self.runtimes():
            lua.execute('''
            M={_localVolumes=volume,_coherentRenderer=renderer}
            CLEAN_RADIANCE={};PROGRESSIVE={lightingAudit={getStatus=function()return {active=capture}end},
              reflectionSampling={isFrozen=function()return false end}}
            GI_EFFECT_NAME='gi';function effectIsEnabled()return giActive end
            ''')
            for name in ('setLocalVolumesEnabled','getLocalVolumeStatus','setLocalVolumeParameter'):
                lua.execute(re.search(r'^function M\.'+name+r'\(.*?\nend' if name=='setLocalVolumesEnabled'
                    else r'^function M\.'+name+r'[^\n]*',MAIN,re.M|re.S).group())
            self.assertFalse(lua.globals().M.setLocalVolumesEnabled(True)[0])
            lua.execute('giActive=true;capture=true')
            self.assertFalse(lua.globals().M.setLocalVolumesEnabled(True)[0])
            lua.execute('capture=false')
            self.assertTrue(lua.globals().M.setLocalVolumesEnabled(True))
            self.assertTrue(lua.globals().M.setLocalVolumesEnabled(False)[0])
        for name in ('disable','onSettingsChanged','onClientStartMission','onClientEndMission','onExtensionUnloaded'):
            body=re.search(r'^function M\.'+name+r'\(.*?\nend',MAIN,re.M|re.S).group()
            self.assertIn('_localVolumes.disable(',body)
        for lua,renderer in backend.CoherentRenderer().runtimes():
            lua.execute(tuner.UI_MOCK)
            lua.globals().volume=lua.execute(SOURCE)
            lua.execute('''
            ui=nil;api.getLocalVolumeStatus=volume.getStatus
            api.setLocalVolumesEnabled=function(v)if v then return volume.enable()end;return volume.disable()end
            api.setLocalVolumeParameter=volume.setParameter
            tab='Lighting & GI';expanded=true
            ''')
            lua.globals().ui=lua.execute((MODULES/'tunerUI.lua').read_text())
            lua.execute('ui.draw(im,api,panels)')
            self.assertFalse(lua.globals().volume.getStatus().requested)
            lua.execute("click='Try local lamp haze##BeamRTVolumes';ui.draw(im,api,panels)")
            self.assertTrue(lua.globals().volume.getStatus().requested)

    def test_light_handoff_is_bounded_read_only_and_uses_selected_native_spotlights(self):
        for lua,api in lamps.NearbyLampShadows().runtimes():
            lua.execute('''
            for i=1,10 do
              local o=lamp(i,i)
              for k,v in pairs({color='1 .8 .5 1',brightness='2',range='20',innerAngle='20',outerAngle='50'})do
                o.advertised[k]=true;o.fields[k]=v
              end
              function o:getTransform()return {getColumn=function(_,n)assert(n==1);return {x=0,y=0,z=-1}end}end
            end
            ''')
            api.enableAutomatic();api.update(.016)
            before=len(lua.globals().writes)
            result=api.getVolumetricLights()
            self.assertEqual(len(result),4)
            self.assertEqual(result[1].id,1)
            self.assertEqual(result[1].direction[3],-1)
            self.assertGreater(result[1].inner,result[1].outer)
            self.assertEqual(len(lua.globals().writes),before)
            lua.execute('objects[1].fields.isEnabled="0";objects[2].fields.brightness="nan"')
            result=api.getVolumetricLights()
            self.assertEqual(result[1].id,3)
            self.assertEqual(len(lua.globals().writes),before)
            api.disable()
            self.assertEqual(len(api.getVolumetricLights()),0)

    def test_shader_has_fixed_deterministic_depth_limited_integration_and_no_shadow_claim(self):
        source=(ROOT/'shaders/beamrt/beamrtLocalVolumeP_v004.hlsl').read_text()
        self.assertIn('i<8',source)
        self.assertIn('min(volumeDistance,rayLength*saturate(depth))',source)
        self.assertIn('if(volumeCount>7.5)',source)
        self.assertNotIn('random',source)
        self.assertNotIn('shadowAtlas',source)
        self.assertIn('if((volumeCount<.5 && emitterCount<.5) || volumeStrength<=0 || volumeDensity<=0) return scene;',source)
        self.assertIn('uniform_sampler2D(sceneTex,0)',source)
        self.assertIn('tex2D(depthTex,IN.uv2)',source)
        self.assertIn('dot(direction,-ray)',source)
        self.assertIn('float4(hdrEncode(hdrDecode(scene.rgb)+scatter*volumeDensity*volumeStrength),scene.a)',source)
        for forbidden in ('settings.setValue','setPosition(', 'jsonWriteFile(', 'loadExtension('):
            self.assertNotIn(forbidden,SOURCE)

if __name__=='__main__':unittest.main()
