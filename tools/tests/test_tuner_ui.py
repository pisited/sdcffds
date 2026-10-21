"""Actual tab presentation + renderer API. No game/UI appearance proof."""
from pathlib import Path
import re
import unittest
import zipfile
import test_coherent_renderer as backend

ROOT = Path(__file__).resolve().parents[2]
MODULES = ROOT / 'lua/ge/extensions/beamrt'
MAIN = (MODULES / 'main.lua').read_text()
UI_MOCK = r'''
tab='Reflections'; expanded=false; click=nil; sliderID=nil; sliderValue=nil
labels={};uiEvents={};tabs={};panelCalls={};tabEnds=0;barEnds=0;writes=0
im={TreeNodeFlags_DefaultOpen=1}
function im.BeginTabBar(name)return true end
function im.EndTabBar()barEnds=barEnds+1 end
function im.BeginTabItem(name)table.insert(tabs,name);return name==tab end
function im.EndTabItem()tabEnds=tabEnds+1 end
function im.TextUnformatted(s)table.insert(labels,s);table.insert(uiEvents,{kind='text',label=s})end
im.TextWrapped=im.TextUnformatted
function im.PushItemWidth()end
function im.PopItemWidth()end
function im.SameLine()end
function im.Separator()end
function im.SetTooltip()end
function im.IsItemHovered()return false end
function im.CollapsingHeader1(s)table.insert(labels,s);return expanded end
function im.BoolPtr(v)return {[0]=v}end
im.FloatPtr=im.BoolPtr
function im.Button(s)table.insert(labels,s);return click==s end
function im.Checkbox(s,p)
 table.insert(labels,s);if click==s then p[0]=not p[0];return true end;return false
end
function im.SliderFloat(s,p)
 table.insert(uiEvents,{kind='slider',label=s})
 table.insert(labels,s);if sliderID==s then p[0]=sliderValue;return true end;return false
end
api={getCoherentSsrStatus=renderer.getStatus,_coherentRenderer=renderer}
function api.setCoherentSsrParameter(k,v)writes=writes+1;return renderer.setParameter(k,v)end
function api.setCoherentSsrEnabled(v)writes=writes+1;if v then return renderer.enable()end;return renderer.disable()end
panels={lighting=function()table.insert(panelCalls,'lighting')end,
 diagnostics=function()table.insert(panelCalls,'diagnostics')end,
 legacy=function()table.insert(panelCalls,'legacy')end}
'''


class TunerUI(unittest.TestCase):
    def runtimes(self):
        for lua, renderer in backend.CoherentRenderer().runtimes():
            lua.execute(UI_MOCK)
            ui = lua.execute((MODULES / 'tunerUI.lua').read_text())
            lua.globals().ui = ui
            yield lua, renderer

    def test_every_tab_is_balanced_and_opening_it_is_non_mutating(self):
        for lua, renderer in self.runtimes():
            for tab, expected in [('Reflections', []), ('Lighting & GI', ['lighting']),
                                  ('Diagnostics', ['diagnostics']), ('Legacy', ['legacy'])]:
                lua.globals().tab = tab
                lua.execute('expanded=true;panelCalls={};tabEnds=0;barEnds=0;ui.draw(im,api,panels)')
                self.assertEqual(list(lua.globals().panelCalls.values()), expected)
                self.assertEqual(lua.globals().tabEnds, 1)
                self.assertEqual(lua.globals().barEnds, 1)
                self.assertEqual(lua.globals().writes, 0)
                self.assertFalse(renderer.getStatus().requested)
                self.assertEqual(lua.eval('(function()local n=0;for _ in pairs(objects)do n=n+1 end;return n end)()'), 1)

    def test_main_reflection_page_excludes_debug_and_legacy_controls(self):
        for lua, renderer in self.runtimes():
            lua.execute("expanded=true;ui.draw(im,api,panels)")
            labels = '\n'.join(lua.globals().labels.values())
            for group in ('Look', 'Quality', 'Noise and temporal stability', 'Water'):
                self.assertIn(group, labels)
            for old in ('Hit-aware', 'Native SSR: dense-ray comparison', 'Raw trace', 'Probe rear camera', 'Capture Lighting Audit'):
                self.assertNotIn(old, labels)
            self.assertEqual(renderer.getOptions().waterColorStrength, 0)

    def test_controls_address_current_renderer_and_do_not_enable_it(self):
        for lua, renderer in self.runtimes():
            lua.execute("expanded=true;click='Rough stability (experimental)##BeamRTSSR_roughStability';ui.draw(im,api,panels)")
            self.assertFalse(renderer.getOptions().roughStability)
            lua.execute("click=nil;sliderID='##BeamRTSSR_faceOnReflectance';sliderValue=.1;ui.draw(im,api,panels)")
            self.assertAlmostEqual(renderer.getOptions().faceOnReflectance, .1)
            self.assertFalse(renderer.getStatus().requested)

    def test_every_full_width_slider_has_a_separate_visible_label_above_it(self):
        expected = {'intensity': 'Reflection strength', 'roughnessEnd': 'Roughness cutoff',
                    'faceOnReflectance': 'Face-on reflectivity', 'surfaceDetail': 'Preserve surface detail',
                    'renderScale': 'Trace resolution', 'traceQuality': 'Trace work budget',
                    'temporalStrength': 'History retention', 'stochasticReuse': 'Spatial reuse',
                    'waterSSRStrength': 'Water reflection strength', 'waterColorStrength': 'Added tint (0 = stock color)',
                    'puddleStrength': 'Procedural puddle coverage', 'virtualParallaxScale': 'Reflection translation'}
        for lua, renderer in self.runtimes():
            lua.execute('expanded=true;ui.draw(im,api,panels)')
            events = list(lua.globals().uiEvents.values())
            seen = set()
            for index, event in enumerate(events):
                if event.kind != 'slider':
                    continue
                self.assertTrue(event.label.startswith('##BeamRTSSR_'))
                key = event.label.removeprefix('##BeamRTSSR_')
                self.assertGreater(index, 0)
                self.assertEqual(events[index-1].kind, 'text')
                self.assertEqual(events[index-1].label, expected[key])
                seen.add(key)
            self.assertEqual(seen, set(expected))
            self.assertEqual(lua.globals().writes, 0)

    def test_debug_restore_is_explicit_and_does_not_start_a_renderer(self):
        for lua, renderer in self.runtimes():
            self.assertTrue(renderer.setParameter('debugView', 20))
            lua.execute("tab='Diagnostics';ui.draw(im,api,panels)")
            self.assertEqual(renderer.getOptions().debugView, 20)
            lua.execute("click='Restore reflection beauty##BeamRTDebug';ui.draw(im,api,panels)")
            self.assertEqual(renderer.getOptions().debugView, 0)
            self.assertFalse(renderer.getStatus().requested)

    def test_legacy_panels_remain_callable_but_closed_headers_do_not_mutate(self):
        for lua, renderer in self.runtimes():
            lua.execute('M=api;M._tunerPanels={};PROGRESSIVE={lastPresetId=nil};TUNING_FILE="test.json";function tuningTooltip()end;M.getPresets=function()return {}end')
            for name in ('lighting', 'diagnostics', 'legacy'):
                function = re.search(r'^function M\._tunerPanels\.' + name + r'\(\).*?^end', MAIN, re.M | re.S)
                self.assertIsNotNone(function)
                lua.execute(function.group())
                lua.execute('M._tunerPanels.' + name + '()')
            self.assertEqual(lua.globals().writes, 0)
            self.assertFalse(renderer.getStatus().requested)

    def test_archive_is_readable_and_contains_the_pre_cleanup_tuner(self):
        path = ROOT / 'archive/legacy-reflections-v0.117-2026-10-20.zip'
        with zipfile.ZipFile(path) as archive:
            self.assertIsNone(archive.testzip())
            old = archive.read('lua/ge/extensions/beamrt/main.lua').decode()
            self.assertIn('local VERSION = "0.117"', old)
            self.assertIn('local function drawTuningWindow()', old)
            self.assertIn('Hit-aware ON', old)
            self.assertIn('lua/ge/extensions/beamrt/nativeSsrEnhancement.lua', archive.namelist())


if __name__ == '__main__':
    unittest.main()
