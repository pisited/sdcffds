"""Real Lua graph and A/B controls; not proof of in-game scheduling or visuals."""
from pathlib import Path
import re
import unittest

from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT = Path(__file__).resolve().parents[2]
MAIN = (ROOT / 'lua/ge/extensions/beamrt/main.lua').read_text()


def method(prefix, name):
    match = re.search(r'function ' + re.escape(prefix + '.' + name) + r'\([^\n]*\).*?\nend', MAIN, re.S)
    assert match, name
    return match.group()


MOCK = r'''
objects={};M={};resets=0;giResets=0;registered=0
function findObject(name)return objects[name]end
function createObject(class)
  local o={fields={},consts={},children={}}
  function o:setField(key,index,value)
    if key=='texture' then assert(index>=0 and index<=5)end
    self.fields[key]=self.fields[key]or{};self.fields[key][index]=value
  end
  function o:getField(key,index)return self.fields[key]and self.fields[key][index]or''end
  function o:getRenderTargetSize()return renderSize end
  function o:setShaderConst(key,value)self.consts[key]=value end
  function o:registerObject(name)
    assert(not objects[name]);assert(self.fields.target[0]);registered=registered+1;objects[name]=self
  end
  function o:add(child)table.insert(self.children,child)end
  return o
end
function setIfPresent(name,key,value)local o=findObject(name);if o then o:setShaderConst(key,value)end end
function effectIsEnabled(name)local o=findObject(name);return o and o.isEnabled==true or false end
function resetReflectionHistory(reason,resetGI)assert(resetGI==false);resets=resets+1 end
function resetTemporalHistory()giResets=giResets+1 end
function beamrtLog()end
view={resolution={x=2560,y=1353}}
renderSize={x=2560,y=1353}
RenderViewManagerInstance={getView=function()return view end}
'''


class ReflectionQualityIntegration(unittest.TestCase):
    def runtimes(self):
        for runtime in (Lua51, LuaJIT):
            lua = runtime(unpack_returned_tuples=True)
            lua.execute(MOCK)
            hit = re.search(r'  reflectionHit = (\{.*?\n  \}),', MAIN, re.S).group(1)
            lua.execute('PROGRESSIVE={reflectionHit=' + hit + r''',
                reflectionReceiverHistory={enabled=true},reflectionSourceReconstruction={enabled=true},
                reflectionLocalResolve={enabled=false,strength=.35},
                reflectionSampling={isFrozen=function()return frozen end},reflectionConvergenceEnabled=false}
                configured=true;frozen=false
                PROGRESSIVE.reflectionHit.configured=function()return configured end
            ''')
            for name in ('createInputs', 'createCopy', 'updateSizes'):
                lua.execute(method('PROGRESSIVE.reflectionHit', name))
            for name in ('setReflectionReceiverHistoryEnabled', 'setReflectionSourceReconstructionEnabled',
                         'getReflectionQualityState'):
                lua.execute(method('M', name))
            lua.globals().REFLECTION_EFFECT_NAME = 'Trace'
            lua.globals().REFLECTION_TEMPORAL_EFFECT_NAME = 'Temporal'
            lua.execute("objects.Trace=createObject('PostEffect');parent=createObject('PostEffect');PROGRESSIVE.reflectionHit.createInputs();PROGRESSIVE.reflectionHit.createCopy(parent)")
            yield lua

    def test_runtime_entries_opt_in_and_old_reference_variants_remain(self):
        for entry in ('beamrtReflectionTraceP_v043.hlsl', 'beamrtReflectionTemporalP_v040.hlsl',
                      'beamrtReflectionHitInputsP_v002.hlsl', 'beamrtReflectionHitCopyP_v002.hlsl'):
            self.assertIn('shaders/beamrt/' + entry, MAIN)
            self.assertTrue((ROOT / 'shaders/beamrt' / entry).is_file())
        for entry in ('beamrtReflectionTraceP_v042.hlsl', 'beamrtReflectionTemporalP_v038.hlsl',
                      'beamrtReflectionHitInputsP_v001.hlsl', 'beamrtReflectionHitCopyP_v001.hlsl'):
            self.assertTrue((ROOT / 'shaders/beamrt' / entry).is_file())

    def test_both_atlases_are_rgba32f_two_planes_before_registration(self):
        for lua in self.runtimes():
            hit = lua.globals().PROGRESSIVE.reflectionHit
            for name in (hit.inputsEffectName, hit.copyEffectName):
                obj = lua.globals().objects[name]
                self.assertEqual(obj.fields.targetScale[0], '1 1')
                self.assertEqual(obj.fields.targetSize[0], '1 2')
                self.assertEqual(obj.fields.targetFormat[0], 'GFXFormatR32G32B32A32F')
            copy = lua.globals().objects[hit.copyEffectName]
            self.assertEqual(copy.fields.texture[4], '#prepass[RT0]')
            self.assertEqual(copy.fields.texture[5], '#prepass[RT1]')
            self.assertEqual(lua.globals().registered, 2)

    def test_retained_copy_is_rewired_without_duplicate_children(self):
        for lua in self.runtimes():
            lua.execute("local o=objects[PROGRESSIVE.reflectionHit.copyEffectName];o:setField('texture',5,'STALE');o:setField('targetScale',0,'1 1');PROGRESSIVE.reflectionHit.createCopy(parent);PROGRESSIVE.reflectionHit.createInputs()")
            copy = lua.globals().objects[lua.globals().PROGRESSIVE.reflectionHit.copyEffectName]
            self.assertEqual(copy.fields.texture[5], '#prepass[RT1]')
            self.assertEqual(copy.fields.targetScale[0], '1 1')
            self.assertEqual(len(lua.globals().parent.children), 1)
            self.assertEqual(lua.globals().registered, 2)

    def test_size_binding_and_explicit_memory_cost(self):
        for lua in self.runtimes():
            lua.execute('PROGRESSIVE.reflectionHit.updateSizes()')
            hit = lua.globals().PROGRESSIVE.reflectionHit
            for name in (hit.inputsEffectName, hit.copyEffectName):
                self.assertEqual(lua.globals().objects[name].consts['$reflectionReceiverSize'], '2560 1353')
                self.assertEqual(lua.globals().objects[name].fields.targetSize[0], '2560 2706')
            status = lua.globals().M.getReflectionQualityState()
            self.assertEqual(status.additionalAtlasBytes, 32 * 2560 * 1353)
            self.assertFalse(status.gameAppearanceVerified)
            lua.globals().M.setReflectionReceiverHistoryEnabled(False)
            self.assertEqual(lua.globals().M.getReflectionQualityState().additionalAtlasBytes, 32 * 2560 * 1353)

    def test_unknown_nonfinite_and_oversized_view_fail_closed(self):
        for lua in self.runtimes():
            for value in ('nil', '{}', '{x=0,y=1}', '{x=0/0,y=100}',
                          '{x=1/0,y=100}', '{x=100,y=8193}', '{x=16385,y=100}'):
                lua.execute('renderSize=' + value + ';PROGRESSIVE.reflectionHit.updateSizes()')
                self.assertEqual(lua.globals().PROGRESSIVE.reflectionHit.receiverSize, '0 0')
                self.assertFalse(lua.globals().PROGRESSIVE.reflectionHit.sizeValid)
                self.assertFalse(lua.globals().M.getReflectionQualityState().receiverHistoryActive)
                self.assertEqual(lua.globals().objects[lua.globals().PROGRESSIVE.reflectionHit.inputsEffectName].fields.targetSize[0], '1 2')
            lua.execute('objects.Trace=nil;PROGRESSIVE.reflectionHit.updateSizes()')
            self.assertEqual(lua.globals().PROGRESSIVE.reflectionHit.receiverSize, '0 0')

    def test_upscaled_display_does_not_define_atlas_extent(self):
        for lua in self.runtimes():
            lua.execute('view.resolution={x=3840,y=2160};renderSize={x=1920,y=1080};PROGRESSIVE.reflectionHit.updateSizes()')
            hit = lua.globals().PROGRESSIVE.reflectionHit
            self.assertEqual(hit.receiverSize, '1920 1080')
            self.assertEqual(lua.globals().objects[hit.inputsEffectName].fields.targetSize[0], '1920 2160')

    def test_internal_resize_and_recovery_clear_history_without_recursion(self):
        for lua in self.runtimes():
            lua.execute('PROGRESSIVE.reflectionHit.updateSizes()')
            for size, changed in (('{x=2560,y=1353}', False), ('{x=1920,y=1080}', True),
                                  ('nil', True), ('nil', False), ('{x=1920,y=1080}', True)):
                lua.execute('reflectionHistoryValid=1;reflectionHistoryWarmupFrames=20;renderSize=' + size + ';PROGRESSIVE.reflectionHit.updateSizes()')
                self.assertEqual(lua.globals().reflectionHistoryValid, 0 if changed else 1)
                self.assertEqual(lua.globals().reflectionHistoryWarmupFrames, 0 if changed else 20)
            self.assertEqual(lua.globals().resets, 0)
            self.assertEqual(lua.globals().giResets, 0)

    def test_unknown_or_oversized_extent_disables_helper_passes(self):
        for lua in self.runtimes():
            lua.execute(r'''
                enabledRequested=true;debugMode=1;reflectionOverlayEnabled=true
                MODE_IDS={reflections=1,diffusegi=2}
                PROGRESSIVE.rayDebugMode=0;PROGRESSIVE.lightingDiagnostic={mode=0}
                PROGRESSIVE.rendererCompatibility={check=function()return {safe=true}end}
                PROGRESSIVE.reflectionColor={halfEffectName='Half',configured=function()return false end}
                function setEffectEnabled(name,value)local o=objects[name];if o then o.isEnabled=value end end
            ''')
            lua.execute(method('PROGRESSIVE.reflectionHit', 'sync'))
            for size, expected in (('{x=1920,y=1080}', True), ('nil', False),
                                   ('{x=1920,y=10000}', False), ('{x=1280,y=720}', True)):
                lua.execute('renderSize=' + size + ';PROGRESSIVE.reflectionHit.updateSizes();PROGRESSIVE.reflectionHit.sync()')
                hit = lua.globals().PROGRESSIVE.reflectionHit
                for name in (hit.inputsEffectName, hit.copyEffectName):
                    self.assertEqual(lua.globals().objects[name].isEnabled, expected)
                self.assertEqual(lua.globals().M.getReflectionQualityState().receiverHistoryActive, expected)

    def test_strict_toggles_reset_only_reflections_and_preserve_graph(self):
        for lua in self.runtimes():
            for name in ('setReflectionReceiverHistoryEnabled', 'setReflectionSourceReconstructionEnabled'):
                setter = lua.globals().M[name]
                before = lua.globals().resets
                for value in (None, 'false', 0, 1, float('nan')):
                    self.assertFalse(setter(value))
                self.assertEqual(lua.globals().resets, before)
                self.assertTrue(setter(True))
                self.assertEqual(lua.globals().resets, before)
                self.assertTrue(setter(False))
                self.assertEqual(lua.globals().resets, before + 1)
                self.assertTrue(setter(False))
                self.assertEqual(lua.globals().resets, before + 1)
            self.assertEqual(lua.globals().giResets, 0)
            self.assertEqual(lua.globals().registered, 2)

    def test_actual_uniform_gates_exclude_frozen_and_convergence(self):
        source_start = MAIN.index('  traceEffect:setShaderConst("$reflectionSourceReconstructionEnabled",')
        source_end = MAIN.index('  traceEffect:setShaderConst("$reflectionSampleCellPixels",', source_start)
        history_start = MAIN.index('  local hitAware = PROGRESSIVE.reflectionHit.configured()')
        history_end = MAIN.index('  local desiredFormat =', history_start)
        for lua in self.runtimes():
            lua.execute("lab={raw=false};traceEffect=objects.Trace;temporal=createObject('PostEffect');objects.Temporal=temporal")
            lua.execute('function applyQuality()\nPROGRESSIVE.reflectionHit.updateSizes()\n' + MAIN[source_start:source_end] + MAIN[history_start:history_end] + '\nend')
            lua.execute('applyQuality()')
            self.assertEqual(lua.globals().traceEffect.consts['$reflectionSourceReconstructionEnabled'], 1)
            self.assertEqual(lua.globals().temporal.consts['$reflectionReceiverHistoryEnabled'], 1)
            for setting in ('frozen=true', 'PROGRESSIVE.reflectionConvergenceEnabled=true'):
                lua.execute(setting + ';configured=false;applyQuality()')
                self.assertEqual(lua.globals().traceEffect.consts['$reflectionSourceReconstructionEnabled'], 0)
                self.assertEqual(lua.globals().temporal.consts['$reflectionReceiverHistoryEnabled'], 0)
                lua.execute('frozen=false;PROGRESSIVE.reflectionConvergenceEnabled=false;configured=true')

    def test_shader_registration_uses_exactly_six_hit_copy_inputs(self):
        block = MAIN[MAIN.index('  createShader(PROGRESSIVE.reflectionHit.copyShaderName,'):]
        block = block[:block.index('\n  })')]
        self.assertEqual(re.findall(r'"(\w+Tex)"', block), ['currentReflectionTex', 'prepassDepthTex',
            'hitInputsTex', 'temporalReflectionTex', 'prepassTex', 'materialSpecTex'])


if __name__ == '__main__':
    unittest.main()
