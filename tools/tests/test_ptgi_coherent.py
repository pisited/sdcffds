"""Actual main methods + actual Coherent graph + staging lease, Lua 5.1/JIT.

Engine objects are mocked: these are CPU ordering/lifecycle contracts, not a
claim that the two renderers have executed together in BeamNG.
"""
from pathlib import Path
import re
import unittest
import test_coherent_renderer as backend

ROOT=Path(__file__).resolve().parents[2]
MAIN=(ROOT/'lua/ge/extensions/beamrt/main.lua').read_text()

def method(name):
    return re.search(r'^function M\.'+name+r'\([^\n]*\).*?\nend',MAIN,re.M|re.S).group()

SETUP=r'''
M={_coherentRenderer=renderer,sharedMeshGI={bound=false}}
findObject=scenetree.findObject
PROGRESSIVE={rendererCompatibility=require('ge/extensions/beamrt/rendererCompatibility'),
 reflectionSampling={isFrozen=function()return frozen==true end},
 reflectionDiagnostic={mode=0},lightingDiagnostic={mode=0},rayDebugMode=0,
 svgf={atrousTargets={'#a','#b','#c'}},
 lightingAudit={getStatus=function()return {active=capturing==true}end,cancel=function()end},
 inputPrep={receiverEffectName='BeamRT_ReceiverResponseFx',auxiliaryEffectName='Aux'},
 reflectionHit={inputsEffectName='HitInputs',copyEffectName='HitCopy',sizeValid=true,
   configured=function()return true end},
 reflectionColor={halfEffectName='Half',atlasEffectName='Atlas',configured=function()return true end},
 waterPreview={enabled=true,effectName='WaterPreview',provider={getStatus=function()return {available=true}end},
   applyConsts=function()return true end},voxel={effectName='Voxel'},reflectionReconstruction={}}
CLEAN_RADIANCE={};MODE_IDS={diffusegi=6,lighting=6,reflections=7,bufferdiag=8,voxeldda=9}
modeName='lighting';debugMode=6;enabledRequested=false;giSourceMode=1;reflectionOverlayEnabled=true
giResets=0;reflectionResets=0;giStrength=.9;surfels={};bufferDiagnosticSource='raw'
BUFFER_DIAGNOSTIC_SOURCES={raw={effectName='Raw'}}
function beamrtLog()end
function finiteNumber(n)return tonumber(n)end
function resetTemporalHistory()giResets=giResets+1 end
function resetReflectionHistory()reflectionResets=reflectionResets+1 end
function applyShaderConsts()end
function applyGIShaderConsts()end
function refreshSurfels()end
function M.openTuner()end
function M.setMeshSunShadowsEnabled()return true end
function M.setMeshLocalLightsEnabled()return true end
function createObjects()error('Unexpected graph recreation')end
function object(name,priority)
 local o=createObject('PostEffect');o:registerObject(name)
 o:setField('renderTime',0,'PFXAfterDiffuse');o:setField('renderBin',0,'')
 o:setField('shader',0,'BeamRT_TestShader');o.renderPriority=priority or 0
 return o
end
'''

class PtgiCoherent(unittest.TestCase):
    def runtimes(self,named=False):
        for lua,renderer in backend.CoherentRenderer().runtimes():
            lua.execute(SETUP)
            lua.globals().M._ptgiCoherent=lua.execute((ROOT/'lua/ge/extensions/beamrt/ptgiCoherent.lua').read_text())
            if named: lua.globals().M._ptgiCoherent.namedHandoff=True
            for name,value in re.findall(r'local (\w+_NAME) = "([^"]+)"',MAIN):
                lua.globals()[name]=value
                lua.globals().object(value)
            lua.execute("for _,n in ipairs({'Aux','HitInputs','HitCopy','Half','Atlas','Voxel','Raw','WaterPreview'})do object(n)end")
            lua.execute("object('BeamRT_SurfelCacheFx',10004);object('BeamRT_ReceiverResponseFx',10003);object('BeamRT_GIFx',10002)")
            lua.execute("objects.BeamRT_ComposeFx:setField('target',0,'$backBuffer')")
            start=MAIN.index('local function effectIsEnabled(')
            section=MAIN[start:MAIN.index('local function setNormalBeamRTEffectsEnabled(',start)]
            for name in ('effectIsEnabled','setEffectEnabled','syncEffectEnablement'):
                section=section.replace('local function '+name+'(','function '+name+'(')
            lua.execute(section)
            for name in ('enable','disable','start','setMode','onPreRender','onClientEndMission',
                         'setReflectionsEnabled','setGIStrength','setRayHitDiagnostic','setLightingDiagnostic'):
                lua.execute(method(name))
            yield lua,renderer,lua.globals().M

    def assert_started(self,lua,api):
        self.assertTrue(api.getPtgiCoherentStatus().active)
        self.assertTrue(lua.eval('objects.BeamRT_GIFx:isEnabled()'))
        self.assertFalse(lua.eval('objects.BeamRT_ReflectionFx:isEnabled()'))
        for name in ('HitInputs','HitCopy','Half','WaterPreview'):
            self.assertFalse(lua.globals().objects[name].isEnabled(lua.globals().objects[name]),name)

    def test_opt_in_combines_gi_with_actual_ssr_graph_without_changing_tuning(self):
        for lua,renderer,api in self.runtimes():
            before=dict(renderer.getOptions().items())
            self.assertFalse(api.getPtgiCoherentStatus().requested)
            self.assertTrue(api.setPtgiCoherentEnabled(True))
            self.assert_started(lua,api)
            self.assertEqual(dict(renderer.getOptions().items()),before)
            self.assertEqual(lua.globals().giStrength,.9)
            for name,priority in (('BeamRT_SurfelCacheFx',48),('BeamRT_ReceiverResponseFx',47),('BeamRT_GIFx',46)):
                obj=lua.globals().objects[name]
                self.assertEqual(obj.getField(obj,'renderTime',0),'PFXBeforeBin')
                self.assertEqual(obj.getField(obj,'renderBin',0),'AfterPostFX')
                self.assertEqual(obj.renderPriority,priority)
            self.assertLess(lua.globals().objects.BeamRTCoherentPostEffectTracePass.renderPriority,46)
            self.assertEqual(lua.eval('objects.BeamRTCoherentPostEffectTracePass:getField("texture",0)'),'$backBuffer')
            for suffix in ('ColorMip1Pass','NativeResolvePass','ApplyPass'):
                obj=lua.globals().objects['BeamRTCoherentPostEffect'+suffix]
                self.assertEqual(obj.getField(obj,'texture',0),'$backBuffer')
            self.assertEqual(lua.eval('objects.BeamRTCoherentPostEffectHiZ0Pass:getField("texture",0)'),'$backBuffer')
            self.assertEqual(lua.eval('objects.BeamRT_ComposeFx:getField("target",0)'),'$backBuffer')
            self.assertFalse(api.getPtgiCoherentStatus().gpuExecutionVerified)
            self.assertTrue(api.disable())
            self.assertFalse(api.getPtgiCoherentStatus().requested)
            self.assertFalse(renderer.getStatus().active)
            self.assertEqual(lua.eval('objects.BeamRT_ComposeFx:getField("target",0)'),'$backBuffer')
            for name,priority in (('BeamRT_SurfelCacheFx',10004),('BeamRT_ReceiverResponseFx',10003),('BeamRT_GIFx',10002)):
                obj=lua.globals().objects[name]
                self.assertEqual(obj.getField(obj,'renderTime',0),'PFXAfterDiffuse')
                self.assertEqual(obj.getField(obj,'renderBin',0),'')
                self.assertEqual(obj.renderPriority,priority)

    def test_repeated_enable_keeps_combined_order_and_legacy_overlay_disabled(self):
        for lua,renderer,api in self.runtimes():
            self.assertTrue(api.setPtgiCoherentEnabled(True))
            self.assertTrue(api.enable())
            for _ in range(8):api.onPreRender(.016,.016,.016)
            self.assert_started(lua,api)
            self.assertFalse(api.setReflectionsEnabled(True)[0])
            self.assertFalse(api.setCoherentSsrParameter('hdrComposite',False)[0])
            self.assertFalse(api.setCoherentSsrParameter('debugView',20)[0])
            self.assertFalse(api.setLightingDiagnostic('identity'))
            self.assertFalse(api.setRayHitDiagnostic('hits'))
            self.assert_started(lua,api)

    def test_named_source_survives_routing_updates_then_restores_standalone_source(self):
        for lua,renderer,api in self.runtimes(named=True):
            self.assertTrue(api.setPtgiCoherentEnabled(True))
            for name,value in (('stochasticRayCount',1),('filteredColor',False),('nativeTemporal',False)):
                self.assertTrue(api.setCoherentSsrParameter(name,value))
                api.onPreRender(.016,.016,.016)
                self.assert_started(lua,api)
                self.assertEqual(lua.eval('objects.BeamRTCoherentPostEffectTracePass:getField("texture",0)'),
                                 '#BeamRT_PTGI_LitScene')
            self.assertTrue(api.disable())
            self.assertTrue(api.setCoherentSsrEnabled(True))
            self.assertEqual(renderer.getStatus().sceneColorSource,'$backBuffer')
            self.assertEqual(lua.eval('objects.BeamRTCoherentPostEffectApplyPass:getField("texture",0)'),'$backBuffer')

    def test_native_conflict_capture_and_wrong_stage_fail_before_combined_enable(self):
        for setup in ('native=true','frozen=true','capturing=true','CLEAN_RADIANCE.build={}',
                      'CLEAN_RADIANCE.materialBatch={}'):
            for lua,renderer,api in self.runtimes():
                lua.execute(setup)
                self.assertFalse(api.setPtgiCoherentEnabled(True)[0],setup)
                self.assertFalse(api.getPtgiCoherentStatus().requested)
                self.assertFalse(lua.eval('objects.BeamRT_GIFx:isEnabled()'))
        for lua,renderer,api in self.runtimes():
            renderer.setParameter('hdrComposite',False)
            self.assertFalse(api.setPtgiCoherentEnabled(True)[0])
            self.assertFalse(renderer.getStatus().requested)

    def test_runtime_conflict_and_pass_loss_stop_both_without_auto_resume(self):
        for setup in ('native=true','objects.BeamRT_GIFx:disable()',
                      "objects.BeamRT_GIFx.renderPriority=10002",
                      "objects.BeamRT_ComposeFx:setField('target',0,'#foreign')",
                      "objects.BeamRTCoherentPostEffectTracePass:setField('texture',0,'#foreign')",
                      'objects.BeamRTCoherentPostEffectTracePass:delete()'):
            for lua,renderer,api in self.runtimes():
                self.assertTrue(api.setPtgiCoherentEnabled(True))
                api.onPreRender(.016,.016,.016)
                lua.execute(setup)
                api.onPreRender(.016,.016,.016)
                self.assertFalse(api.getPtgiCoherentStatus().requested,setup)
                self.assertFalse(renderer.getStatus().requested,setup)
                self.assertFalse(lua.eval('objects.BeamRT_GIFx:isEnabled()'),setup)
                lua.execute('native=false')
                api.onPreRender(.016,.016,.016)
                self.assertFalse(renderer.getStatus().requested)
                self.assertFalse(lua.globals().enabledRequested)

    def test_restoration_failure_is_retained_for_retry(self):
        for lua,renderer,api in self.runtimes():
            self.assertTrue(api.setPtgiCoherentEnabled(True))
            lua.execute("rawset(objects.BeamRT_GIFx,'setField',function()error('setter unavailable')end)")
            self.assertFalse(api.disable())
            self.assertFalse(api.getPtgiCoherentStatus().requested)
            self.assertFalse(api.enable()[0])
            lua.execute("rawset(objects.BeamRT_GIFx,'setField',nil)")
            self.assertTrue(api.disable())
            self.assertEqual(lua.eval('objects.BeamRT_GIFx.renderPriority'),10002)

    def test_foreign_replacement_does_not_receive_original_stage_fields(self):
        for lua,renderer,api in self.runtimes():
            self.assertTrue(api.setPtgiCoherentEnabled(True))
            lua.execute("object('BeamRT_GIFx',777):setField('renderBin',0,'Foreign')")
            api.onPreRender(.016,.016,.016)
            self.assertFalse(api.getPtgiCoherentStatus().requested)
            self.assertEqual(lua.eval('objects.BeamRT_GIFx.renderPriority'),777)
            self.assertEqual(lua.eval('objects.BeamRT_GIFx:getField("renderBin",0)'),'Foreign')

    def test_standalone_gi_and_mission_end_restore_staging(self):
        for action in ('start','onClientEndMission'):
            for lua,renderer,api in self.runtimes():
                self.assertTrue(api.setPtgiCoherentEnabled(True))
                api[action]()
                self.assertFalse(api.getPtgiCoherentStatus().requested)
                self.assertFalse(renderer.getStatus().requested)
                self.assertEqual(lua.eval('objects.BeamRT_GIFx.renderPriority'),10002)
                self.assertEqual(lua.eval('objects.BeamRT_GIFx:isEnabled()'),action=='start')

    def test_combined_settings_apply_gi_only_not_legacy_ssr(self):
        for lua,renderer,api in self.runtimes():
            self.assertTrue(api.setPtgiCoherentEnabled(True))
            lua.execute(method('applySettings'))
            # Refuse invocation if these legacy preset entries are not skipped.
            lua.execute("M.setReflectionStrength=function()error('legacy SSR mutated')end")
            before=dict(renderer.getOptions().items())
            self.assertTrue(api.applySettings(lua.table_from({'giStrength':1.2,'reflectionsEnabled':True,'reflectionStrength':2})))
            self.assertEqual(lua.globals().giStrength,1.2)
            self.assertEqual(dict(renderer.getOptions().items()),before)
            self.assert_started(lua,api)

    def test_gi_resets_invalidate_ssr_only_while_combined(self):
        for lua,renderer,api in self.runtimes():
            reset=re.search(r'^local function resetTemporalHistory\([^\n]*\).*?\nend',MAIN,re.M|re.S).group()
            lua.execute(reset.replace('local function ','function ',1))
            self.assertTrue(api.setCoherentSsrEnabled(True))
            for _ in range(12):api.onPreRender(.016,.016,.016)
            self.assertTrue(renderer.getStatus().accumulationReady)
            lua.execute("resetTemporalHistory('standalone GI control',false)")
            self.assertTrue(renderer.getStatus().accumulationReady)
            self.assertTrue(api.setPtgiCoherentEnabled(True))
            for _ in range(12):api.onPreRender(.016,.016,.016)
            self.assertTrue(renderer.getStatus().accumulationReady)
            lua.execute("resetTemporalHistory('combined GI control',false)")
            self.assertFalse(renderer.getStatus().accumulationReady)
            self.assertEqual(lua.globals().historyValid,0)
            self.assert_started(lua,api)

    def test_partial_stage_setup_rolls_back_before_rendering(self):
        for lua,renderer,api in self.runtimes():
            lua.execute("""
            local o=objects.BeamRT_ReceiverResponseFx
            local original=o.setField
            rawset(o,'setField',function(self,k,i,v)
              if k=='renderBin' and v=='AfterPostFX' then error('stage setup refused')end
              return original(self,k,i,v)
            end)
            """)
            self.assertFalse(api.setPtgiCoherentEnabled(True)[0])
            self.assertFalse(renderer.getStatus().requested)
            self.assertFalse(api.getPtgiCoherentStatus().requested)
            self.assertFalse(lua.eval('objects.BeamRT_GIFx:isEnabled()'))
            self.assertEqual(lua.eval('objects.BeamRT_GIFx.renderPriority'),10002)

    def test_startup_callback_exception_releases_both_renderers_and_stages(self):
        for lua,renderer,api in self.runtimes():
            lua.execute("""
            calls=0
            function applyShaderConsts()
              calls=calls+1
              if calls==2 then error('constant upload failed')end
            end
            """)
            self.assertFalse(api.setPtgiCoherentEnabled(True)[0])
            self.assertFalse(renderer.getStatus().requested)
            self.assertFalse(api.getPtgiCoherentStatus().requested)
            self.assertFalse(lua.eval('objects.BeamRT_GIFx:isEnabled()'))
            self.assertEqual(lua.eval('objects.BeamRT_GIFx.renderPriority'),10002)

    def test_producer_view_captures_cannot_interrupt_combined_sources(self):
        for lua,renderer,api in self.runtimes():
            self.assertTrue(api.setPtgiCoherentEnabled(True))
            for name in ('publishMaterialCache','publishMaterialV2Caches','refreshCleanRadianceDiagnostics'):
                lua.execute(method(name))
                self.assertFalse(api[name]('baseColor')[0],name)
                self.assert_started(lua,api)

    def test_manual_reflections_join_active_gi_and_repeated_enable_keeps_both(self):
        for named in (False,True):
            for lua,renderer,api in self.runtimes(named=named):
                self.assertTrue(api.start())
                self.assertTrue(lua.eval('objects.BeamRT_GIFx:isEnabled()'))
                self.assertFalse(renderer.getStatus().requested)
                self.assertTrue(api.setCoherentSsrEnabled(True))
                self.assert_started(lua,api)
                lua.execute('traceIdentity=objects.BeamRTCoherentPostEffectTracePass')
                for _ in range(12):api.onPreRender(.016,.016,.016)
                self.assertTrue(api.setCoherentSsrEnabled(True))
                self.assert_started(lua,api)
                self.assertTrue(lua.eval('objects.BeamRTCoherentPostEffectTracePass==traceIdentity'))
                self.assertTrue(renderer.getStatus().accumulationReady)

    def test_named_source_is_opt_in_cannot_change_live_and_combined_stops_volumes(self):
        for lua,renderer,api in self.runtimes():
            self.assertFalse(api.getPtgiCoherentStatus().namedHandoff)
            self.assertFalse(api.setPtgiNamedHandoffEnabled('yes')[0])
            self.assertTrue(api.setPtgiNamedHandoffEnabled(True))
            self.assertFalse(api.getPtgiCoherentStatus().requested)
            lua.execute('''
            volumeStops=0
            M._localVolumes={requested=true,disable=function()
              volumeStops=volumeStops+1;M._localVolumes.requested=false;return true end}
            ''')
            self.assertTrue(api.setPtgiCoherentEnabled(True))
            self.assert_started(lua,api)
            self.assertEqual(api.getPtgiCoherentStatus().sceneTarget,'#BeamRT_PTGI_LitScene')
            self.assertEqual(lua.eval('objects.BeamRT_ComposeFx:getField("target",0)'),'#BeamRT_PTGI_LitScene')
            self.assertGreater(lua.globals().volumeStops,0)
            self.assertFalse(lua.globals().M._localVolumes.requested)
            self.assertFalse(api.setPtgiNamedHandoffEnabled(False)[0])
            self.assertTrue(api.disable())
            self.assertTrue(api.setPtgiNamedHandoffEnabled(False))
            self.assertTrue(api.setPtgiCoherentEnabled(True))
            self.assertEqual(api.getPtgiCoherentStatus().sceneTarget,'$backBuffer')

    def test_read_only_report_includes_debug_volume_and_actual_pass_bindings(self):
        for lua,renderer,api in self.runtimes():
            self.assertTrue(api.setPtgiCoherentEnabled(True))
            lua.execute('function jsonEncode()return "report"end;M._localVolumes={getStatus=function()return {requested=false}end}')
            before=dict(renderer.getOptions().items())
            report=api.logPtgiCoherentStatus()
            self.assertEqual(report.rayDebugMode,0)
            self.assertFalse(report.volumes.requested)
            self.assertEqual(len(report.passes),8)
            self.assertEqual(report.passes[2].target,'$backBuffer')
            self.assertEqual(report.passes[5].source,'$backBuffer')
            self.assertEqual(dict(renderer.getOptions().items()),before)
            self.assert_started(lua,api)

    def test_combined_start_restores_beauty_from_ray_lighting_and_coherent_debug_views(self):
        for setup in ('PROGRESSIVE.rayDebugMode=8', 'PROGRESSIVE.lightingDiagnostic.mode=1',
                      "renderer.setParameter('debugView',50)"):
            for lua,renderer,api in self.runtimes():
                lua.execute(setup)
                before=dict(renderer.getOptions().items())
                self.assertTrue(api.setPtgiCoherentEnabled(True),setup)
                self.assert_started(lua,api)
                self.assertEqual(lua.globals().PROGRESSIVE.rayDebugMode,0)
                self.assertEqual(lua.globals().PROGRESSIVE.lightingDiagnostic.mode,0)
                self.assertEqual(renderer.getOptions().debugView,0)
                for key,value in before.items():
                    if key!='debugView':self.assertEqual(renderer.getOptions()[key],value,key)

    def test_capture_guard_does_not_clear_debug_views_or_start_any_pipeline(self):
        for lua,renderer,api in self.runtimes():
            lua.execute("capturing=true;PROGRESSIVE.rayDebugMode=8;renderer.setParameter('debugView',50)")
            self.assertFalse(api.setPtgiCoherentEnabled(True)[0])
            self.assertEqual(lua.globals().PROGRESSIVE.rayDebugMode,8)
            self.assertEqual(renderer.getOptions().debugView,50)
            self.assertFalse(renderer.getStatus().requested)

if __name__=='__main__':unittest.main()
