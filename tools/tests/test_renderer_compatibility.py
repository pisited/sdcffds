"""Fail-closed native SSR policy, executed in Lua 5.1 and LuaJIT.

These mocked API checks do not prove live buffer contents or GPU ordering.
"""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime as Lua51Runtime
from lupa.luajit21 import LuaRuntime as LuaJITRuntime

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / 'lua/ge/extensions/beamrt/rendererCompatibility.lua').read_text(encoding='utf-8')
RUNTIMES = (('Lua 5.1', Lua51Runtime), ('LuaJIT', LuaJITRuntime))


class RendererCompatibility(unittest.TestCase):
    def run_case(self, setup, assertion):
        for name, runtime in RUNTIMES:
            with self.subTest(runtime=name, setup=setup):
                lua = runtime(unpack_returned_tuples=True)
                lua.execute('''
                  writes=0; creates=0; queries=0; lookups=0
                  configured=false; object=nil
                  settings={getValue=function(key)
                    assert(key=='PostFXSSREnabled');queries=queries+1;return configured
                  end,setValue=function()writes=writes+1;error('must not write settings')end}
                  scenetree={findObject=function(name)
                    assert(name=='PostFxSSSRObject');lookups=lookups+1;return object
                  end}
                  function createObject()creates=creates+1;error('must not create objects')end
                ''')
                lua.execute(setup)
                policy = lua.execute(SOURCE)
                assertion(lua, policy)
                self.assertEqual(lua.globals().writes, 0)
                self.assertEqual(lua.globals().creates, 0)

    def expect(self, safe, native_ssr, reason=None):
        def assertion(lua, policy):
            state = policy.check()
            self.assertEqual(state.safe, safe)
            self.assertEqual(state.nativeSSR, native_ssr)
            self.assertIsInstance(state.reason, str)
            self.assertTrue(state.reason)
            if reason:
                self.assertIn(reason, state.reason)
        return assertion

    def test_explicit_off_with_absent_object_is_safe(self):
        self.run_case('', self.expect(True, 'off', 'no native SSR object'))

    def test_explicit_off_and_actual_off_is_safe(self):
        self.run_case('object={isEnabled=function()return false end}',
                      self.expect(True, 'off', 'both report disabled'))

    def test_actual_on_wins_over_false_unknown_or_broken_settings(self):
        for setup in ('configured=false', 'configured=nil', "configured='false'",
                      "settings.getValue=function()error('broken getter')end"):
            self.run_case(setup + ';object={isEnabled=function()return true end}',
                          self.expect(False, 'on', 'reuses'))

    def test_requested_on_is_not_proof_of_off_even_with_disabled_object(self):
        for setup in ('object=nil', 'object={isEnabled=function()return false end}'):
            self.run_case('configured=true;' + setup,
                          self.expect(False, 'unknown', 'requested'))

    def test_unknown_setting_never_implies_disabled(self):
        for value in ('nil', "'false'", "'true'", '0', '1', '{}'):
            for object_value in ('nil', '{isEnabled=function()return false end}'):
                self.run_case('configured=' + value + ';object=' + object_value,
                              self.expect(False, 'unknown', 'setting'))

    def test_missing_broken_and_malformed_setting_apis_fail_closed(self):
        for setup in ('settings=nil', 'settings=false', 'settings={}',
                      'settings={getValue=false}',
                      "settings={getValue=function()error('failed')end}",
                      "settings=setmetatable({},{__index=function()error('failed')end})"):
            self.run_case(setup, self.expect(False, 'unknown', 'setting'))

    def test_lookup_failure_never_means_object_absent(self):
        for setup in ('scenetree=nil', 'scenetree=false', 'scenetree={}',
                      'scenetree={findObject=42}',
                      "scenetree={findObject=function()error('failed')end}",
                      "scenetree=setmetatable({},{__index=function()error('failed')end})"):
            self.run_case(setup, self.expect(False, 'unknown', 'lookup'))

    def test_invalid_objects_or_enabled_results_fail_closed(self):
        for object_value in ('false', 'true', '1', "'object'", '{}',
                             '{isEnabled=false}',
                             "{isEnabled=function()error('failed')end}",
                             "setmetatable({},{__index=function()error('failed')end})",
                             '{isEnabled=function()return nil end}',
                             "{isEnabled=function()return 'false' end}",
                             '{isEnabled=function()return 0 end}',
                             '{isEnabled=function()return {} end}'):
            self.run_case('object=' + object_value,
                          self.expect(False, 'unknown', 'enabled state'))

    def test_observation_does_not_mutate_native_object_or_config(self):
        def assertion(lua, policy):
            for _ in range(3):
                self.assertTrue(policy.check().safe)
            self.assertEqual(lua.globals().object.marker, 'unchanged')
            self.assertEqual(lua.globals().calls, 3)
            self.assertFalse(lua.globals().configured)
            self.assertEqual(lua.globals().queries, 3)
            self.assertEqual(lua.globals().lookups, 3)
        self.run_case('''
          calls=0;object={marker='unchanged',isEnabled=function(self)
            assert(self==object);calls=calls+1;return false
          end,enable=function()error('must not enable')end,
          disable=function()error('must not disable')end}
        ''', assertion)

    def test_update_tracks_state_and_reason_transitions_with_no_copy_pollution(self):
        def assertion(lua, policy):
            initial = policy.getStatus()
            self.assertFalse(initial.safe)
            self.assertEqual(initial.nativeSSR, 'unknown')
            changed, state = policy.update()
            self.assertTrue(changed)
            self.assertTrue(state.safe)
            state.safe = False
            state.reason = 'caller pollution'
            status = policy.getStatus()
            self.assertTrue(status.safe)
            self.assertNotEqual(status.reason, 'caller pollution')
            status.nativeSSR = 'caller pollution'
            self.assertEqual(policy.getStatus().nativeSSR, 'off')
            self.assertFalse(policy.update()[0])
            lua.execute('object={isEnabled=function()return false end}')
            self.assertTrue(policy.update()[0])  # Evidence/reason changed.
            self.assertFalse(policy.update()[0])
            lua.execute('object.isEnabled=function()return true end')
            changed, state = policy.update()
            self.assertTrue(changed)
            self.assertEqual(state.nativeSSR, 'on')
            self.assertFalse(policy.update()[0])
            lua.execute('object=nil;configured=false')
            changed, state = policy.update()
            self.assertTrue(changed)
            self.assertTrue(state.safe)
        self.run_case('', assertion)

    def test_check_is_fresh_and_does_not_change_last_published_status(self):
        def assertion(lua, policy):
            policy.update()
            lua.execute('object={isEnabled=function()return true end}')
            self.assertEqual(policy.check().nativeSSR, 'on')
            self.assertEqual(policy.getStatus().nativeSSR, 'off')
            lua.execute('object=nil;configured=false')
            self.assertTrue(policy.check().safe)
            self.assertFalse(policy.update()[0])
        self.run_case('', assertion)


if __name__ == '__main__':
    unittest.main(verbosity=2)
