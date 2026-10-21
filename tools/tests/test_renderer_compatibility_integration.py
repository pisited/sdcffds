"""Execute the actual main.lua interlock with mocked engine objects.

These checks establish control/cleanup behavior, not game scheduling or visuals.
"""
from pathlib import Path
import re
import unittest

from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT = Path(__file__).resolve().parents[2]
MAIN = (ROOT / 'lua/ge/extensions/beamrt/main.lua').read_text()
POLICY = (ROOT / 'lua/ge/extensions/beamrt/rendererCompatibility.lua').read_text()

MOCK = r'''
objects={};configured=false;settingWrites=0;giResets=0;reflectionResets=0;bufferStops=0;buildStops=0
auditActive=false;auditStops=0
settings={getValue=function()return configured end,setValue=function()settingWrites=settingWrites+1 end}
scenetree={findObject=function(name)return objects[name]end}
function findObject(name)return objects[name]end
function object(name)
  local o={enabled=false,fields={}}
  function o:isEnabled()return self.enabled end
  function o:enable()self.enabled=true end
  function o:disable()self.enabled=false end
  function o:setField(key,index,value)self.fields[key]=self.fields[key]or{};self.fields[key][index]=value end
  objects[name]=o;return o
end
M={sharedMeshGI={bound=false}}
PROGRESSIVE={inputPrep={receiverEffectName='Receiver'},voxel={effectName='Voxel'},
  waterPreview={enabled=false,effectName='WaterPreview'},
  lightingAudit={cancel=function()if auditActive then auditStops=auditStops+1;auditActive=false end end},
  reflectionHit={inputsEffectName='HitInputs',copyEffectName='HitCopy',sizeValid=true,configured=function()return true end},
  reflectionColor={halfEffectName='Half',configured=function()return true end},
  rayDebugMode=0,lightingDiagnostic={mode=0},reflectionReconstruction={}}
BUFFER_DIAGNOSTIC_SOURCES={raw={effectName='Raw'}}
MODE_IDS={diffusegi=1,reflections=2,bufferdiag=3,voxeldda=4}
enabledRequested=true;debugMode=1;reflectionOverlayEnabled=true;giSourceMode=0
function resetTemporalHistory()giResets=giResets+1 end
function resetReflectionHistory()reflectionResets=reflectionResets+1 end
function beamrtLog()end
function finiteNumber(n)return tonumber(n)end
CLEAN_RADIANCE={finishBuild=function()buildStops=buildStops+1;CLEAN_RADIANCE.build=nil end}
package.loaded['ge/extensions/beamrt/giVisibilityBuffer']={disable=function()bufferStops=bufferStops+1 end}
'''


class MainCompatibility(unittest.TestCase):
    def runtimes(self):
        for runtime in (Lua51, LuaJIT):
            lua = runtime(unpack_returned_tuples=True)
            lua.execute(MOCK)
            lua.globals().PROGRESSIVE.rendererCompatibility = lua.execute(POLICY)
            for name, value in re.findall(r'local (\w+_EFFECT_NAME|GI_TRACE_SHADER_NAME) = "([^"]+)"', MAIN):
                lua.globals()[name] = value
                if name.endswith('_EFFECT_NAME'):
                    lua.globals().object(value)
            lua.execute("for _,name in ipairs({'Receiver','Voxel','HitInputs','HitCopy','Half','Raw'})do object(name)end")
            start = MAIN.index('local function effectIsEnabled(')
            end = MAIN.index('local function setNormalBeamRTEffectsEnabled(', start)
            section = MAIN[start:end]
            for name in ('effectIsEnabled', 'setEffectEnabled', 'syncEffectEnablement'):
                section = section.replace('local function ' + name + '(', 'function ' + name + '(')
            lua.execute(section)
            start = MAIN.index('function M.onPreRender(')
            lua.execute(MAIN[start:MAIN.index('\nfunction M.onUpdate(', start)])
            yield lua

    def test_safe_path_enables_original_gi_and_reflection_selection(self):
        for lua in self.runtimes():
            lua.execute('syncEffectEnablement()')
            for name in ('GI_EFFECT_NAME', 'SURFEL_CACHE_EFFECT_NAME', 'REFLECTION_EFFECT_NAME'):
                self.assertTrue(lua.globals().objects[lua.globals()[name]].enabled)
            self.assertTrue(lua.globals().objects.HitInputs.enabled)
            self.assertFalse(lua.globals().objects[lua.globals().DEBUG_EFFECT_NAME].enabled)
            self.assertEqual(lua.globals().settingWrites, 0)

    def test_native_on_or_unknown_never_selects_a_debug_fallback(self):
        for setup in ("configured=true;object('PostFxSSSRObject'):enable()", 'configured=nil'):
            for lua in self.runtimes():
                lua.execute('syncEffectEnablement();' + setup + ';M.onPreRender(.016,.016,.016)')
                for name in ('GI_EFFECT_NAME', 'SURFEL_CACHE_EFFECT_NAME', 'REFLECTION_EFFECT_NAME', 'DEBUG_EFFECT_NAME'):
                    self.assertFalse(lua.globals().objects[lua.globals()[name]].enabled)
                for name in ('HitInputs', 'HitCopy', 'Half', 'Receiver', 'Voxel', 'Raw'):
                    self.assertFalse(lua.globals().objects[name].enabled)
                self.assertTrue(lua.globals().enabledRequested)
                self.assertEqual(lua.globals().settingWrites, 0)

    def test_toggle_resets_histories_and_resumes_requested_mode_without_repeated_resets(self):
        for lua in self.runtimes():
            lua.execute('M.onPreRender(.016,.016,.016)')
            baseline = lua.globals().giResets
            lua.execute("configured=true;object('PostFxSSSRObject'):enable();M.onPreRender(.016,.016,.016)")
            self.assertEqual(lua.globals().giResets, baseline + 1)
            lua.execute('M.onPreRender(.016,.016,.016)')
            self.assertEqual(lua.globals().giResets, baseline + 1)
            lua.execute("configured=false;objects.PostFxSSSRObject:disable();M.onPreRender(.016,.016,.016)")
            self.assertEqual(lua.globals().giResets, baseline + 2)
            self.assertEqual(lua.globals().reflectionResets, baseline + 2)
            self.assertTrue(lua.globals().objects[lua.globals().GI_EFFECT_NAME].enabled)
            self.assertTrue(lua.globals().objects[lua.globals().REFLECTION_EFFECT_NAME].enabled)
            self.assertEqual(lua.globals().debugMode, 1)
            self.assertFalse(lua.globals().objects.PostFxSSSRObject.enabled)

    def test_user_disabled_state_does_not_resume_on_native_toggle(self):
        for lua in self.runtimes():
            lua.execute('enabledRequested=false;configured=true;M.onPreRender(.016,.016,.016);configured=false;M.onPreRender(.016,.016,.016)')
            self.assertFalse(lua.globals().objects[lua.globals().GI_EFFECT_NAME].enabled)
            self.assertFalse(lua.globals().objects[lua.globals().REFLECTION_EFFECT_NAME].enabled)

    def test_long_render_gap_invalidates_gi_not_only_reflections(self):
        for lua in self.runtimes():
            lua.execute('M.onPreRender(.016,.016,.016);syncEffectEnablement()')
            before=lua.globals().giResets
            lua.execute('M.onPreRender(1,1,1)')
            self.assertEqual(lua.globals().giResets,before+1)
            lua.execute('M.onPreRender(.016,.016,.016)')
            self.assertEqual(lua.globals().giResets,before+1)

    def test_independent_reflection_preparation_cannot_bypass_guard(self):
        for lua in self.runtimes():
            lua.execute('configured=true;PROGRESSIVE.reflectionHit.sync()')
            for name in ('HitInputs', 'HitCopy', 'Half'):
                self.assertFalse(lua.globals().objects[name].enabled)

    def test_blocked_transition_retires_optional_gi_path_and_cancels_build(self):
        for lua in self.runtimes():
            lua.execute('M.onPreRender(.016,.016,.016);M.sharedMeshGI.bound=true;CLEAN_RADIANCE.build={};configured=true;M.onPreRender(.016,.016,.016)')
            self.assertFalse(lua.globals().M.sharedMeshGI.bound)
            self.assertFalse(lua.globals().M.sharedMeshGI.bufferEffective)
            self.assertGreater(lua.globals().bufferStops, 0)
            self.assertEqual(lua.globals().buildStops, 1)
            self.assertIsNone(lua.globals().CLEAN_RADIANCE.build)

    def test_public_status_is_fresh_and_does_not_claim_an_early_capture(self):
        for lua in self.runtimes():
            status = lua.globals().M.getRendererCompatibilityStatus()
            self.assertTrue(status.normalEffectsAllowed)
            self.assertFalse(status.earlyMaterialCaptureImplemented)
            lua.execute('configured=true')
            self.assertFalse(lua.globals().M.getRendererCompatibilityStatus().normalEffectsAllowed)

    def test_native_object_toggle_cancels_active_audit_without_settings_hook(self):
        for lua in self.runtimes():
            lua.execute("M.onPreRender(.016,.016,.016);auditActive=true;object('PostFxSSSRObject'):enable();M.onPreRender(.016,.016,.016)")
            self.assertFalse(lua.globals().auditActive)
            self.assertEqual(lua.globals().auditStops, 1)

    def test_safe_transition_preserves_material_publisher_view_isolation(self):
        for lua in self.runtimes():
            lua.execute("materialCachePublication={};M.onPreRender(.016,.016,.016)")
            self.assertFalse(lua.globals().objects[lua.globals().GI_EFFECT_NAME].enabled)
            self.assertFalse(lua.globals().objects[lua.globals().REFLECTION_EFFECT_NAME].enabled)
            lua.execute("object('PostFxSSSRObject');M.onPreRender(.016,.016,.016)")
            self.assertFalse(lua.globals().objects[lua.globals().GI_EFFECT_NAME].enabled)
            self.assertFalse(lua.globals().objects[lua.globals().REFLECTION_EFFECT_NAME].enabled)
            self.assertIsNotNone(lua.globals().materialCachePublication)

    def test_both_start_and_existing_graph_paths_use_guard_and_settings_hook_rechecks(self):
        sync = MAIN[MAIN.index('local function syncEffectEnablement()'):MAIN.index('function PROGRESSIVE.refreshRendererCompatibility()')]
        self.assertIn('PROGRESSIVE.rendererCompatibility.check().safe', sync)
        self.assertNotIn('useGI = enabledRequested', sync)
        self.assertNotIn('useReflections = enabledRequested', sync)
        for name in ('refreshCleanRadianceDiagnostics', 'runLightingAudit'):
            body = MAIN[MAIN.index('function M.' + name + '('):]
            self.assertLess(body.index('if not compatibility.safe'), body.index('if materialCachePublication'))
        settings_hook = MAIN[MAIN.index('function M.onSettingsChanged()'):]
        self.assertIn('PROGRESSIVE.refreshRendererCompatibility()', settings_hook.split('\nend', 1)[0])


if __name__ == '__main__':
    unittest.main()
