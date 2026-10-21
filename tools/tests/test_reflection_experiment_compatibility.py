"""Actual companion entry/retirement paths; no GPU scheduling claims."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT = Path(__file__).resolve().parents[2]
MODULES = (('reflectionSourceProbe', 'BeamRT_SourceProbe', 'mutated'),
           ('reflectionConvergence', 'BeamRT_Convergence', 'mainMutated'))
BAD_STATUS = ("main.getRendererCompatibilityStatus=nil",
              "main.getRendererCompatibilityStatus=false",
              "main.getRendererCompatibilityStatus=function()error('failed')end",
              "main.getRendererCompatibilityStatus=function()return nil end",
              "main.getRendererCompatibilityStatus=function()return true end",
              "main.getRendererCompatibilityStatus=function()return {} end",
              "main.getRendererCompatibilityStatus=function()return {safe=false}end",
              "main.getRendererCompatibilityStatus=function()return {safe='true'}end",
              "main.getRendererCompatibilityStatus=function()return {safe=1}end")
MOCK = r'''
  mutations=0;writes=0;pops=0;deletes=0;disables=0;manifests=0;creates=0
  main={};objects={};extensions={beamrt_main=main}
  settings={setValue=function()writes=writes+1 end}
  function createObject()creates=creates+1;error('must not create')end
  function restore()mutations=mutations+1;return true end
  for _,key in ipairs({'setReflectionSourceProbeTarget','setReflectionConvergenceEnabled',
      'applySettings','setLightingDiagnostic','setRayHitDiagnostic','restoreReflectionDiagnosticState',
      'setMode','enable','disable','openTuner','closeTuner'})do main[key]=restore end
  main.getRendererCompatibilityStatus=function()return {safe=true}end
  main.getReflectionConvergenceEnabled=function()return false end
  main.getLightingAuditStatus=function()return {active=false}end
  main.getReflectionSourceProbeTarget=function()return nil end
  scenetree={findObject=function(name)return objects[name]end}
  function jsonWriteFile()manifests=manifests+1;return true end
  function log()end
  function fixtureObject(name)
    objects[name]={disable=function()disables=disables+1 end,
      delete=function()deletes=deletes+1;objects[name]=nil end}
  end
'''


class ReflectionExperimentCompatibility(unittest.TestCase):
    def cases(self):
        for module, prefix, mutation_key in MODULES:
            for runtime in (Lua51, LuaJIT):
                lua = runtime(unpack_returned_tuples=True)
                lua.execute(MOCK)
                source = (ROOT / f'lua/ge/extensions/beamrt/{module}.lua').read_text()
                # Only fixture arming is injected; actual start, pre-render,
                # cleanup, restoration, manifest and status paths are unchanged.
                arm = '''
                  function M.fixtureArm()
                    active={saved={settings={mode='lighting'},state={enabled=true,tunerOpen=false}},
                      directory='fixture',images={},copies={},draws=0,stage=1,case=1,view=0,
                      camera={0,0,0,0,0,0,1,60,1280,720},elapsed=0,age=0,phase='warmup',
                      pause={popPauseRequest=function()pops=pops+1;return true end},%s=true}
                    owned={'%sMeanFx','%sNativeFx'}
                    for _,name in ipairs(owned)do fixtureObject(name)end
                  end
                  return M
                ''' % (mutation_key, prefix, prefix)
                source = source.rsplit('return M', 1)[0] + arm
                policy = lua.execute(source)
                yield module, lua, policy

    def test_entry_refuses_unknown_unsafe_or_malformed_status_without_mutation(self):
        for bad_status in BAD_STATUS:
            for module, lua, policy in self.cases():
                with self.subTest(module=module, status=bad_status):
                    lua.execute(bad_status)
                    self.assertFalse(policy.start())
                    self.assertEqual(lua.globals().mutations, 0)
                    self.assertEqual(lua.globals().writes, 0)
                    self.assertEqual(lua.globals().creates, 0)
                    self.assertEqual(lua.globals().manifests, 0)
                    self.assertFalse(policy.getStatus().active)

    def test_active_unsafe_transition_restores_and_destroys_owned_passes(self):
        for bad_status in BAD_STATUS:
            for module, lua, policy in self.cases():
                with self.subTest(module=module, status=bad_status):
                    policy.fixtureArm()
                    lua.execute(bad_status)
                    policy.onPreRender(.016)
                    status = policy.getStatus()
                    self.assertFalse(status.active)
                    self.assertTrue(status.restored)
                    self.assertIn('renderer compatibility changed', status.reason)
                    self.assertGreater(lua.globals().mutations, 0)
                    self.assertEqual(lua.globals().deletes, 2)
                    self.assertGreaterEqual(lua.globals().disables, 1)
                    self.assertEqual(lua.globals().pops, 1)
                    self.assertEqual(lua.globals().manifests, 1)
                    self.assertEqual(lua.globals().writes, 0)
                    policy.onPreRender(.016)
                    self.assertEqual(lua.globals().pops, 1)

    def test_explicit_safe_status_keeps_active_warmup_running(self):
        for module, lua, policy in self.cases():
            with self.subTest(module=module):
                lua.execute('''
                  core_camera={getPosition=function()return {x=0,y=0,z=0}end,
                    getQuat=function()return {x=0,y=0,z=0,w=1}end,getFovDeg=function()return 60 end}
                  RenderViewManagerInstance={getView=function()return {resolution={x=1280,y=720}}end}
                  main.getReflectionSamplingState=function()return {frozen=false,name='ggx'}end
                  main.getReflectionReconstructionState=function()return {name='playable'}end
                ''')
                lua.execute("main.getLightingAuditState=function()return {mode='" +
                            ('lighting' if module == 'reflectionSourceProbe' else 'reflections') + "'}end")
                policy.fixtureArm()
                policy.onPreRender(.016)
                self.assertTrue(policy.getStatus().active)
                self.assertEqual(lua.globals().deletes, 0)
                self.assertEqual(lua.globals().mutations, 0)
                self.assertEqual(lua.globals().writes, 0)
                self.assertEqual(lua.globals().pops, 0)


if __name__ == '__main__':
    unittest.main()
