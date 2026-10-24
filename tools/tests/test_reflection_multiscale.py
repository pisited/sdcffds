"""Actual Lua graph/setters with mocked PostFX objects, plus source guards.

The separate GPU fixture executes actual shaders on controlled inputs. Neither
these graph mocks nor that fixture certifies BeamNG execution/appearance.
"""
from pathlib import Path
import re
import unittest
from lupa.lua51 import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
MAIN = (ROOT / 'lua/ge/extensions/beamrt/main.lua').read_text()


def method(name):
    match = re.search(r'function M\.' + name + r'\([^\n]*\).*?\nend', MAIN, re.S)
    assert match is not None, name
    return match.group()


MOCK = r'''
objects={};M={};resets=0
function findObject(name)return objects[name]end
function createObject(class)
  local o={class=class,fields={},consts={},children={}}
  function o:setField(key,index,value)
    if key=='texture' then assert(index>=0 and index<=5)end
    self.fields[key]=self.fields[key]or{};self.fields[key][index]=value
  end
  function o:getField(key,index)return self.fields[key]and self.fields[key][index]or''end
  function o:setShaderConst(key,value)self.consts[key]=value end
  function o:registerObject(name)assert(not objects[name],'duplicate object');self.name=name;objects[name]=self end
  function o:add(child)table.insert(self.children,child)end
  function o:delete()objects[self.name]=nil end
  return o
end
function syncEffectEnablement()end
function resetReflectionHistory()resets=resets+1 end
function beamrtLog()end
function finiteNumber(v)
  local n=tonumber(v);if not n or n~=n or n==math.huge or n==-math.huge then return nil end;return n
end
function setIfPresent(name,key,value)local o=findObject(name);if o then o:setShaderConst(key,value)end end
reflectionHistoryValid=1;reflectionHistoryDepthTolerance=.01;reflectionMaxRoughness=.34
'''


class ReflectionMultiscale(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(MOCK)
        config = re.search(r'  reflectionVariance = (\{.*?\n  \}),', MAIN, re.S).group(1)
        self.lua.execute('PROGRESSIVE={reflectionVariance=' + config + r''',
            reflectionColor={atlasTarget='#Color',createEffects=function()end},
            reflectionHit={copyEffectName='HitCopy',createInputs=function()end,createCopy=function()end},
            reflectionDiagnostic={mode=0},reflectionSampling={mode=1},
            reflectionReconstruction={mode=1},reflectionConvergenceEnabled=false,cameraMotion=0}''')
        for name, value in re.findall(r'local (REFLECTION_\w+|STATE_NAME) = "([^"]+)"', MAIN):
            self.lua.globals()[name] = value
        start = MAIN.index('local function createReflectionEffect()')
        end = MAIN.index('\nfunction PROGRESSIVE.voxel.createEffect()', start)
        self.lua.execute(MAIN[start:end].replace('local function createReflectionEffect()', 'function createReflectionEffect()', 1))
        for name in ('setReflectionVarianceEnabled', 'setReflectionVariancePasses',
                     'setReflectionVarianceStrength', 'getReflectionVarianceState'):
            self.lua.execute(method(name))
        self.main = self.lua.globals().M

    def obj(self, name):
        return self.lua.globals().objects[name]

    def order(self):
        names = []

        def visit(obj):
            self.assertNotIn(obj.name, names, 'cycle or reused graph node')
            names.append(obj.name)
            for child in obj.children.values():
                visit(child)

        visit(self.obj('BeamRT_ReflectionFx'))
        return names

    def test_default_off_and_original_graph_restored_without_variance_passes(self):
        self.assertFalse(self.main.getReflectionVarianceState().enabled)
        self.lua.globals().createReflectionEffect()
        original = self.order()
        self.assertEqual(len(original), 4)
        self.main.setReflectionVarianceEnabled(True)
        self.assertEqual(len(self.order()), 9)
        self.main.setReflectionVarianceEnabled(False)
        self.assertEqual(self.order(), original)
        for name in ('BeamRT_ReflectionMomentsFx', 'BeamRT_ReflectionAtrousFx',
                     'BeamRT_ReflectionAtrousFx2', 'BeamRT_ReflectionAtrousFx3', 'BeamRT_ReflectionMomentsHistoryCopyFx'):
            self.assertIsNone(self.obj(name))

    def test_three_scales_read_previous_output_and_preserve_unfiltered_history(self):
        self.main.setReflectionVarianceEnabled(True)
        order = self.order()
        expected = ['BeamRT_ReflectionFx', 'BeamRT_ReflectionMomentsFx',
                    'BeamRT_ReflectionTemporalFx', 'BeamRT_ReflectionAtrousFx',
                    'BeamRT_ReflectionAtrousFx2', 'BeamRT_ReflectionAtrousFx3',
                    'BeamRT_ReflectionComposeFx', 'BeamRT_ReflectionHistoryCopyFx',
                    'BeamRT_ReflectionMomentsHistoryCopyFx']
        self.assertEqual(order, expected)
        variance = self.lua.globals().PROGRESSIVE.reflectionVariance
        for i in range(1, 4):
            obj = self.obj(variance.atrousEffectNames[i])
            self.assertEqual(obj.fields.texture[0], '#BeamRT_TemporalReflection' if i == 1 else variance.atrousTargets[i - 1])
            self.assertEqual(obj.fields.target[0], variance.atrousTargets[i])
            self.assertEqual(obj.fields.targetFormat[0], 'GFXFormatR16G16B16A16F')
        self.assertEqual(self.obj('BeamRT_ReflectionComposeFx').fields.texture[1], variance.atrousTargets[3])
        self.assertEqual(self.obj('BeamRT_ReflectionHistoryCopyFx').fields.texture[0], '#BeamRT_TemporalReflection')
        for name in ('BeamRT_ReflectionMomentsFx', 'BeamRT_ReflectionMomentsHistoryCopyFx'):
            self.assertEqual(self.obj(name).fields.targetFormat[0], 'GFXFormatR32G32B32A32F')

    def test_single_three_single_switches_rebuild_without_duplicate_or_stale_passes(self):
        self.main.setReflectionVarianceEnabled(True)
        self.assertTrue(self.main.setReflectionVariancePasses(1))
        self.assertEqual(len(self.order()), 7)
        self.assertIsNone(self.obj('BeamRT_ReflectionAtrousFx2'))
        self.assertIsNone(self.obj('BeamRT_ReflectionAtrousFx3'))
        self.assertEqual(self.obj('BeamRT_ReflectionComposeFx').fields.texture[1], '#BeamRT_VarianceReflection')
        self.assertTrue(self.main.setReflectionVariancePasses(3))
        self.assertEqual(len(self.order()), 9)
        self.assertTrue(self.main.setReflectionVarianceEnabled(True))
        self.assertEqual(len(self.order()), 9)
        self.main.setReflectionVariancePasses(1)
        self.assertEqual(len(self.order()), 7)

    def test_actual_constant_binding_steps_and_mirror_audit_convergence_bypass(self):
        start = MAIN.index('  local varianceActive =')
        end = MAIN.index('  local colorFilter =', start)
        section = MAIN[start:end]
        self.lua.execute('lab={raw=false};effectiveRoughness=.35;function applyVariance(frozen)\n' + section + '\nend')
        self.main.setReflectionVarianceEnabled(True)
        self.lua.globals().applyVariance(False)
        for name, step in (('BeamRT_ReflectionAtrousFx', 1), ('BeamRT_ReflectionAtrousFx2', 2), ('BeamRT_ReflectionAtrousFx3', 4)):
            self.assertEqual(self.obj(name).consts['$reflectionAtrousStep'], step)
            self.assertEqual(self.obj(name).consts['$reflectionVarianceStrength'], .65)
        for change in ('reflectionSampling.mode=0', 'reflectionReconstruction.mode=0',
                       'reflectionDiagnostic.mode=1', 'reflectionConvergenceEnabled=true'):
            self.lua.execute('PROGRESSIVE.' + change)
            self.lua.globals().applyVariance(False)
            self.assertEqual(self.obj('BeamRT_ReflectionAtrousFx3').consts['$reflectionVarianceStrength'], 0)
            self.lua.execute('PROGRESSIVE.reflectionSampling.mode=1;PROGRESSIVE.reflectionReconstruction.mode=1;PROGRESSIVE.reflectionDiagnostic.mode=0;PROGRESSIVE.reflectionConvergenceEnabled=false')
        self.lua.globals().applyVariance(True)
        self.assertEqual(self.obj('BeamRT_ReflectionAtrousFx3').consts['$reflectionVarianceStrength'], 0)

    def test_invalid_control_values_leave_state_and_graph_unchanged(self):
        self.main.setReflectionVarianceEnabled(True)
        for value in (0, 2, 4, '3', float('nan'), float('inf')):
            self.assertFalse(self.main.setReflectionVariancePasses(value))
        for value in (float('nan'), float('inf'), 'unknown'):
            self.assertFalse(self.main.setReflectionVarianceStrength(value))
        self.assertEqual(self.main.getReflectionVarianceState().passes, 3)
        self.assertEqual(self.main.getReflectionVarianceState().strength, .65)
        self.assertEqual(len(self.order()), 9)

    def test_gpu_fixture_and_shader_guards_preserve_required_boundaries(self):
        shader = (ROOT / 'shaders/beamrt/beamrtReflectionAtrousP_v001.hlsl').read_text()
        for guard in ('!all(isfinite(center))', '!all(isfinite(moments))', '!all(isfinite(neighbor))',
                      'relativeDepth >= 0.025', 'roughness <= 0.08', 'return center;', 'center.a);'):
            self.assertIn(guard, shader)
        fixture = (ROOT / 'native/lighting/reflection_filter_test.cpp').read_text()
        for assertion in ('threeStats.second<oneStats.second*.70', 'threeStats.first-rawStats.first',
                          'valid zero neighbors', 'depth/normal/roughness/F0 boundary', 'wide scales blurred',
                          'step one changed', 'invalid lifetime neighbors', 'zero strength did not preserve'):
            self.assertIn(assertion, fixture)
        self.assertIn('DXGI_FORMAT_R16G16B16A16_FLOAT', fixture)


if __name__ == '__main__':
    unittest.main()
