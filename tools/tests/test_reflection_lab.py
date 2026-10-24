"""Transient lab policy and actual uniform uploads, in both supported Lua VMs."""
from pathlib import Path
import re
import unittest
from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT
from test_sssr_fork import MOCK, MAIN, method

ROOT = Path(__file__).resolve().parents[2]
POLICY = (ROOT / 'lua/ge/extensions/beamrt/reflectionLab.lua').read_text()
UPLOAD = re.search(r'local function applyReflectionShaderConsts\(\).*?\nend', MAIN, re.S).group()
CONTEXT = r'''
REFLECTION_TEMPORAL_EFFECT_NAME='Temporal';REFLECTION_COMPOSE_EFFECT_NAME='Compose';STATE_NAME='State'
reflectionStepSize=.28;reflectionThickness=.24;reflectionNormalBias=.04
reflectionMaxSteps=48;reflectionMaxDistance=48;reflectionMaxRoughness=.35
reflectionTemporalBlend=.22;reflectionHistoryDepthTolerance=.004;reflectionDenoiseStrength=.5
reflectionHistoryValid=1;reflectionHistoryWarmupFrames=0;reflectionStrength=.75
PROGRESSIVE.reflectionLab={mode='normal',policy=policy}
PROGRESSIVE.lightingAudit={getStatus=function()return {active=auditActive==true}end}
PROGRESSIVE.reflectionTuning={sampleCellPixels=1,noiseSeed=0,sourceFootprintScale=1,filterRadiusScale=1}
PROGRESSIVE.reflectionSourceReconstruction={enabled=true}
PROGRESSIVE.reflectionHit.updateSizes=function()end
PROGRESSIVE.reflectionHit.configured=function()return false end
PROGRESSIVE.reflectionHit.sizeValid=false
PROGRESSIVE.reflectionColor={halfEffectName='Half',configured=function()return true end,updateSizes=function()end}
PROGRESSIVE.reflectionVariance={enabled=true,strength=.65,scale=1,passes=1,
 momentsEffectName='Moments',momentsCopyEffectName='MomentsCopy',atrousEffectNames={'Atrous'},atrousTargets={'Variance'}}
PROGRESSIVE.reflectionReceiverHistory={enabled=true}
PROGRESSIVE.reflectionDiagnostic={mode=0}
PROGRESSIVE.reflectionLocalResolve={enabled=true,strength=.35}
PROGRESSIVE.reflectionSampling.mode=1;PROGRESSIVE.reflectionSampling.sampleIndex=3
PROGRESSIVE.reflectionReconstruction.frameDelta=1/60
PROGRESSIVE.cameraMotion=0
for _,name in ipairs({'Trace','Temporal','Compose','Moments','MomentsCopy','Atrous'})do
 objects[name]={fields={shader='Original'},uniforms={},enabled=true,
  getField=function(self,key,index)return self.fields[key..tostring(index)]or self.fields[key]end,
  setField=function(self,key,index,value)self.fields[key..tostring(index)]=value end,
  setShaderConst=function(self,key,value)self.uniforms[key]=value end}
end
function setIfPresent(name,key,value)if objects[name]then objects[name]:setShaderConst(key,value)end end
'''


class ReflectionLab(unittest.TestCase):
    def runtimes(self):
        for runtime in (Lua51, LuaJIT):
            lua = runtime(unpack_returned_tuples=True)
            lua.execute(MOCK)
            lua.globals().policy = lua.execute(POLICY)
            lua.execute(CONTEXT)
            lua.execute(UPLOAD.replace('local function ', 'function ', 1))
            for name in ('setReflectionLabProfile', 'getReflectionLabStatus'):
                lua.execute(method(name))
            yield lua

    def test_profiles_are_comparisons_with_fresh_immutable_defaults(self):
        for lua in self.runtimes():
            policy = lua.globals().policy
            self.assertEqual([x.id for x in policy.list().values()], ['normal', 'coverage', 'raw', 'punch', 'settled'])
            policy.resolve('punch').gain = 100
            self.assertEqual(policy.resolve('punch').gain, 8)
            self.assertEqual(policy.resolve('normal').lookups, 0)
            for value in (None, True, 1, 'PUNCH', 'cinematic'):
                self.assertIsNone(policy.resolve(value))

    def test_selection_is_transient_and_does_not_enable_or_change_mode(self):
        for lua in self.runtimes():
            self.assertTrue(lua.globals().M.setReflectionLabProfile('punch'))
            self.assertEqual(lua.globals().debugMode, 2)
            self.assertFalse(lua.globals().enabledRequested)
            self.assertEqual(len(lua.globals().events), 0)
            self.assertEqual(lua.globals().resets, 1)
            self.assertTrue(lua.globals().M.setReflectionLabProfile('normal'))
            self.assertFalse(lua.globals().M.getReflectionLabStatus().saved)

    def test_invalid_and_idempotent_requests_do_not_mutate(self):
        for lua in self.runtimes():
            for value in (None, 1, True, '', 'cinematic'):
                self.assertFalse(lua.globals().M.setReflectionLabProfile(value)[0])
            self.assertTrue(lua.globals().M.setReflectionLabProfile('normal'))
            self.assertEqual(lua.globals().resets, 0)

    def test_active_diagnostics_and_captures_block_profile_changes(self):
        for change in ('frozen=true', 'auditActive=true', 'PROGRESSIVE.reflectionConvergenceEnabled=true',
                       "PROGRESSIVE.reflectionSourceProbeTarget='#Captured'"):
            for lua in self.runtimes():
                lua.execute(change)
                self.assertFalse(lua.globals().M.setReflectionLabProfile('punch')[0])
                self.assertEqual(lua.globals().resets, 0)

    def test_actual_upload_normal_retains_tuning_and_onefold_gain(self):
        for lua in self.runtimes():
            lua.execute("PROGRESSIVE.sssrFork.backend='fork';applyReflectionShaderConsts()")
            objects = lua.globals().objects
            self.assertEqual(objects.Trace.uniforms['$reflectionForkWork'], '0 0.000')
            self.assertEqual(objects.Trace.uniforms['$reflectionMaxRoughness'], .35)
            self.assertEqual(objects.Compose.uniforms['$reflectionLabGain'], 1)
            self.assertEqual(objects.Temporal.uniforms['$reflectionTemporalBlend'], .22)
            self.assertEqual(objects.Temporal.uniforms['$reflectionDenoiseStrength'], .5)

    def test_coverage_changes_work_not_occlusion_thickness_or_user_settings(self):
        for lua in self.runtimes():
            lua.execute("PROGRESSIVE.sssrFork.backend='fork';M.setReflectionLabProfile('coverage')")
            trace = lua.globals().objects.Trace.uniforms
            self.assertEqual(trace['$reflectionForkWork'], '2048 64.000')
            self.assertEqual(trace['$reflectionMaxRoughness'], .65)
            self.assertEqual(trace['$reflectionThickness'], .24)
            self.assertEqual(trace['$reflectionNormalBias'], .04)
            self.assertEqual(lua.globals().reflectionMaxRoughness, .35)
            self.assertTrue(lua.globals().M.setReflectionLabProfile('normal'))
            self.assertEqual(trace['$reflectionMaxRoughness'], .35)

    def test_raw_disables_all_display_source_and_history_smoothing(self):
        for lua in self.runtimes():
            lua.execute("PROGRESSIVE.sssrFork.backend='fork';M.setReflectionLabProfile('raw')")
            objects = lua.globals().objects
            for uniform in ('$reflectionSourceReconstructionEnabled', '$reflectionColorFilterEnabled'):
                self.assertEqual(objects.Trace.uniforms[uniform], 0)
            self.assertEqual(objects.Temporal.uniforms['$reflectionTemporalBlend'], 1)
            self.assertEqual(objects.Temporal.uniforms['$reflectionDenoiseStrength'], 0)
            self.assertEqual(objects.Temporal.uniforms['$reflectionReconstructionMode'], 0)
            self.assertEqual(objects.Atrous.uniforms['$reflectionVarianceStrength'], 0)
            self.assertEqual(objects.Compose.uniforms['$reflectionLocalResolveEnabled'], 0)
            self.assertEqual(objects.Compose.uniforms['$reflectionLabGain'], 1)

    def test_settled_does_not_override_frozen_audit_contract(self):
        for lua in self.runtimes():
            lua.execute("PROGRESSIVE.sssrFork.backend='fork';M.setReflectionLabProfile('settled')")
            uniforms = lua.globals().objects.Temporal.uniforms
            self.assertEqual(uniforms['$reflectionTemporalBlend'], .04)
            self.assertEqual(uniforms['$reflectionDenoiseStrength'], .65)
            self.assertEqual(uniforms['$reflectionLabCurrentWeight'], .04)
            lua.execute('frozen=true;applyReflectionShaderConsts()')
            self.assertEqual(uniforms['$reflectionTemporalBlend'], 1)
            self.assertEqual(uniforms['$reflectionDenoiseStrength'], 0)
            self.assertEqual(uniforms['$reflectionLabCurrentWeight'], 0)
            self.assertEqual(lua.globals().objects.Trace.uniforms['$reflectionForkWork'], '2048 64.000')

    def test_probe_and_convergence_suspend_without_forgetting_lab_selection(self):
        for change in ('PROGRESSIVE.reflectionConvergenceEnabled=true', "PROGRESSIVE.reflectionSourceProbeTarget='#Captured'"):
            for lua in self.runtimes():
                lua.execute("PROGRESSIVE.sssrFork.backend='fork';M.setReflectionLabProfile('punch');" + change + ';applyReflectionShaderConsts()')
                self.assertEqual(lua.globals().objects.Compose.uniforms['$reflectionLabGain'], 1)
                self.assertEqual(lua.globals().objects.Trace.uniforms['$reflectionForkWork'], '0 0.000')
                self.assertEqual(lua.globals().M.getReflectionLabStatus().id, 'punch')
                self.assertEqual(lua.globals().M.getReflectionLabStatus().effectiveProfile, 'normal')

    def test_experimental_reference_retains_its_trace_geometry_controls(self):
        for lua in self.runtimes():
            lua.globals().M.setReflectionLabProfile('punch')
            objects = lua.globals().objects
            self.assertIsNone(objects.Trace.uniforms['$reflectionForkWork'])
            self.assertEqual(objects.Trace.uniforms['$reflectionMaxRoughness'], .35)
            self.assertEqual(objects.Compose.uniforms['$reflectionLabGain'], 8)

    def test_ui_buttons_only_select_the_requested_comparison(self):
        start = MAIN.index('  if im.CollapsingHeader1("Reflection comparison lab"')
        block = MAIN[start:MAIN.index('\n  if im.CollapsingHeader1("Native SSR:', start)]
        for label, profile in (('More coverage', 'coverage'), ('Raw', 'raw'), ('8x punch', 'punch'), ('Settled', 'settled')):
            for lua in self.runtimes():
                lua.execute('function drawLab()\n' + block + '\nend')
                lua.globals().clicked = label + '##ReflectionLab'
                lua.globals().drawLab()
                self.assertEqual(lua.globals().M.getReflectionLabStatus().id, profile)
                self.assertFalse(lua.globals().enabledRequested)

    def test_shader_and_audit_contracts(self):
        trace = (ROOT / 'shaders/beamrt/nativeSsr/traceP_v001.hlsl').read_text()
        adapter = (ROOT / 'shaders/beamrt/nativeSsr/adapter.h.hlsl').read_text()
        compose = (ROOT / 'shaders/beamrt/beamrtReflectionComposeP_v026.hlsl').read_text()
        audit = (ROOT / 'lua/ge/extensions/beamrt/lightingAudit.lua').read_text()
        self.assertIn('step < 2048u', adapter)
        self.assertIn('remaining -= cost', adapter)
        self.assertIn('out int failureReason', adapter)
        self.assertIn('failureReason == BEAMRT_SSR_NATIVE_VALIDATION ? 2 : 1', trace)
        self.assertIn('forkConfidence * beamrtEdgeConfidence', trace)
        self.assertLess(compose.index('response *= labGain'), compose.index('float3 baseLinear'))
        self.assertIn('originalReflectionRenderer = run.saved.reflectionRenderer', audit)
        self.assertIn('run.pending.reflectionRenderer =', audit)
        self.assertIn('PTGI + BeamRT SSSR fork active', MAIN)
        settings = method('getSettings')
        self.assertNotIn('reflectionLab', settings)


if __name__ == '__main__':
    unittest.main()
