"""Four bounded gameplay presets, exercised in Lua 5.1 and LuaJIT 2.1.

These settings tests do not establish in-game performance or appearance.
"""
import hashlib
import json
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'lua/ge/extensions/beamrt/presets.lua').read_text()
IDS = ('performance', 'balanced', 'quality', 'cinematic')
ALIASES = {
    'experimental': 'balanced', 'userbest': 'quality', 'maxquality': 'cinematic',
    'beautymax': 'cinematic', 'beautyreflect': 'cinematic',
    'ptgiplay': 'balanced', 'ptgiplayreflect': 'balanced',
    'ptgimax': 'quality', 'ptgimaxreflect': 'quality',
    'ultra': 'quality', 'showcase': 'quality', 'clean': 'quality',
}


def plain(table):
    """Normalize whole-number Lua doubles consistently across both runtimes."""
    result = {}
    for key, value in table.items():
        if isinstance(value, float) and value.is_integer():
            value = int(value)
        result[key] = value
    return result


class TuningPresets(unittest.TestCase):
    def modules(self):
        for runtime in (Lua51, LuaJIT):
            lua = runtime(unpack_returned_tuples=True)
            # The module has no game, filesystem, or settings dependencies.
            lua.execute('io=nil;os=nil;require=nil;jsonReadFile=nil;jsonWriteFile=nil')
            yield lua, lua.execute(SOURCE)

    def test_exactly_four_canonical_choices_in_order(self):
        for _, module in self.modules():
            entries = module.list()
            self.assertEqual(len(entries), 4)
            self.assertEqual(tuple(entries[i].id for i in range(1, 5)), IDS)
            self.assertEqual(tuple(entries[i].label for i in range(1, 5)),
                             ('Performance', 'Balanced', 'Quality', 'Cinematic'))
            self.assertTrue(all(entries[i].description for i in range(1, 5)))

    def test_fresh_lists_and_resolved_tables_cannot_mutate_presets(self):
        for _, module in self.modules():
            entries = module.list()
            entries[1].label = 'Changed'
            entries[1].id = 'injected'
            self.assertEqual(module.list()[1].label, 'Performance')
            self.assertEqual(module.list()[1].id, 'performance')
            first, canonical = module.resolve('quality')
            expected = plain(first)
            first.giPathCount = 999
            first.reflectionReceiverHistoryEnabled = False
            first.injected = True
            second, second_name = module.resolve('quality')
            self.assertEqual(plain(second), expected)
            self.assertEqual(canonical, second_name)

    def test_all_fifteen_legacy_names_resolve_without_fifteen_ui_entries(self):
        for _, module in self.modules():
            legacy = dict(ALIASES, performance='performance', balanced='balanced', cinematic='cinematic')
            self.assertEqual(len(legacy), 15)
            for name, expected in legacy.items():
                result, canonical = module.resolve(name)
                baseline, _ = module.resolve(expected)
                self.assertEqual(canonical, expected)
                self.assertEqual(plain(result), plain(baseline), name)
            self.assertEqual(len(module.list()), 4)

    def test_case_whitespace_and_invalid_names(self):
        for lua, module in self.modules():
            self.assertEqual(module.resolve('  QUALITY\t')[1], 'quality')
            for name in (None, False, True, 0, 1, float('nan'), '', ' ', 'ultra2', '../quality'):
                self.assertEqual(module.resolve(name), (None, None), repr(name))
            self.assertEqual(module.resolve(lua.table()), (None, None))

    def test_bounded_monotonic_gi_work_and_stable_lighting_baseline(self):
        for _, module in self.modules():
            presets = [plain(module.resolve(name)[0]) for name in IDS]
            work = []
            for preset in presets:
                self.assertEqual(preset['rayMarcher'], 'screendda')
                self.assertEqual(preset['giRenderScale'], 1)
                self.assertEqual(preset['giPathCount'], preset['screenDdaMaxPaths'])
                self.assertLessEqual(preset['giPathCount'], 2)
                self.assertLessEqual(preset['screenDdaMaxSteps'], 48)
                self.assertLessEqual(preset['rayMaxSteps'], 64)
                work.append(preset['giPathCount'] * preset['screenDdaMaxSteps'])
            self.assertEqual(work, [16, 24, 32, 96])
            self.assertTrue(all(left < right for left, right in zip(work, work[1:])))
            for key in ('giSource', 'giEstimator', 'giStrength', 'giExposure', 'worldGIStrength',
                        'radianceSource', 'reflectionStrength', 'reflectionSamplingMode',
                        'reflectionReconstruction'):
                self.assertEqual(len({preset[key] for preset in presets}), 1, key)
            self.assertEqual(len({frozenset(preset) for preset in presets}), 1)

    def test_experimental_choices_are_explicit_and_three_scale_blur_stays_off(self):
        for _, module in self.modules():
            for name in IDS:
                preset = module.resolve(name)[0]
                self.assertTrue(preset.reflectionsEnabled)
                self.assertEqual(preset.reflectionSamplingMode, 'ggx')
                self.assertEqual(preset.reflectionReconstruction, 'playable')
                self.assertTrue(preset.reflectionSourceReconstructionEnabled)
                self.assertFalse(preset.reflectionVarianceEnabled)
                self.assertEqual(preset.reflectionVariancePasses, 1)
                self.assertEqual(preset.reflectionVarianceStrength, .65)
                self.assertEqual(preset.reflectionLocalResolveEnabled, name in ('quality', 'cinematic'))
                self.assertEqual(preset.reflectionLocalResolveStrength, .35)
                self.assertEqual(preset.reflectionHitAwareEnabled, name != 'performance')
                self.assertEqual(preset.reflectionReceiverHistoryEnabled, name != 'performance')
                self.assertIsNone(preset.reflectionConvergenceEnabled)
                self.assertIsNone(preset.reflectionDiagnostic)

    def test_snapshots_match_between_lua_implementations(self):
        snapshots = []
        for _, module in self.modules():
            encoded = json.dumps({name: plain(module.resolve(name)[0]) for name in IDS},
                                 sort_keys=True, separators=(',', ':'))
            snapshots.append(hashlib.sha256(encoded.encode()).hexdigest())
        self.assertEqual(snapshots[0], snapshots[1])
        self.assertEqual(snapshots[0], '4cbda0c1ca94378da3613e14253ecdc7564a7ec517efc5a673dd86d0b0d0cac0')


if __name__ == '__main__':
    unittest.main()
