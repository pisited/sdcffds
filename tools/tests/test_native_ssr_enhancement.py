"""Native tuning ownership contracts, not live native rendering/GPU proof."""
from pathlib import Path
import unittest

from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT


SOURCE = (Path(__file__).resolve().parents[2] /
          'lua/ge/extensions/beamrt/nativeSsrEnhancement.lua').read_text(encoding='utf-8')

MOCK = r'''
writes=0;queries=0;fieldReads=0;fieldWrites=0;typedWrites=0;typedReads=0;settingsReads=0;settingsWrites=0
creates=0;deletes=0;enableCalls=0;disableCalls=0;writeLog={}
function newObject(id,value)
  local o={id=id,class='PostFxSSSR',value=tostring(value),enabled=true,
    fields={samplesPerQuad={type='int'},resolutionDivisor={type='int'}},divisor='2'}
  function o:getClassName()return self.class end
  function o:getID()return self.id end
  function o:getFields()if self.metadataFailure then error('metadata failed')end;return self.fields end
  function o:isEnabled()if self.enabledFailure then error('enabled query failed')end;return self.enabled end
  function o:getField(name,index)
    assert(index==0);fieldReads=fieldReads+1
    if name=='resolutionDivisor' then
      if self.divisorFailure then error('divisor unavailable')end
      return self.divisor
    end
    assert(name=='samplesPerQuad')
    if self.readFailure or(self.afterWriteReadFailure and self.hasWritten)then error('field read failed')end
    return self.value
  end
  function o:setField(name,index,value)
    assert(name=='samplesPerQuad'and index==0 and type(value)=='string')
    writes=writes+1;fieldWrites=fieldWrites+1;writeLog[#writeLog+1]={id=self.id,value=value}
    if value=='4'and self.enhanceMode=='throw-before'then error('enhance failed before write')end
    if value=='4'and self.enhanceMode=='false-before'then return false end
    if value~='4'and self.restoreMode=='throw-before'then error('restore failed before write')end
    if value=='4'and self.enhanceMode=='clamp'then self.value='2'else self.value=value end
    self.hasWritten=true
    if value=='4'and self.nativeOffOnWrite then self.enabled=false end
    if value=='4'and self.replaceOnWrite then object=newObject(self.id,'2')end
    if value=='4'and self.enhanceMode=='throw-after'then error('enhance failed after write')end
    if value~='4'and self.restoreMode=='throw-after'then error('restore failed after write')end
  end
  function o:enable()enableCalls=enableCalls+1;error('must not enable native SSR')end
  function o:disable()disableCalls=disableCalls+1;error('must not disable native SSR')end
  function o:delete()deletes=deletes+1;error('must not delete native SSR')end
  return o
end
object=newObject(42,'1')
function makeTyped()
  object.fields={};object.nativeValue=tonumber(object.value);object.nativeDivisor=2
  local mt={[1]={},[2]={}}
  mt[1].samplesPerQuad=function(self)
    typedReads=typedReads+1
    if self.readFailure or(self.afterWriteReadFailure and self.hasWritten)then error('typed read failed',0)end
    if self.changeBindingOnRead then mt[2].samplesPerQuad=self.replacementSetter end
    if self.replaceObjectOnRead then object=newObject(self.id,'2')end
    return self.nativeValue
  end
  mt[2].samplesPerQuad=function(self,value)
    assert(type(value)=='number');writes=writes+1;typedWrites=typedWrites+1
    writeLog[#writeLog+1]={id=self.id,value=value,typed=true}
    if value==4 and self.enhanceMode=='throw-before'then error('typed enhance before write',0)end
    if value==4 and self.enhanceMode=='false-before'then return false end
    if value~=4 and self.restoreMode=='throw-before'then error('typed restore before write',0)end
    if value==4 and self.enhanceMode=='clamp'then self.nativeValue=2 else self.nativeValue=value end
    self.hasWritten=true
    if value==4 and self.nativeOffOnWrite then self.enabled=false end
    if value==4 and self.replaceSetterOnWrite then mt[2].samplesPerQuad=self.replacementSetter end
    if value==4 and self.enhanceMode=='throw-after'then error('typed enhance after write',0)end
    if value~=4 and self.restoreMode=='throw-after'then error('typed restore after write',0)end
  end
  mt[1].resolutionDivisor=function(self)
    if self.divisorFailure then error('typed divisor failed',0)end
    return self.nativeDivisor
  end
  -- Model the installed binding's separate getter/setter dispatch tables.
  mt.__index=function(self,key)
    local getter=rawget(mt[1],key);if type(getter)=='function'then return getter(self)end
  end
  mt.__newindex=function(self,key,value)
    local setter=rawget(mt[2],key)
    if type(setter)=='function'then return setter(self,value)end
    rawset(self,key,value)
  end
  setmetatable(object,mt)
  function object:getDynamicFields()return{'samplesPerQuad'}end
  return mt
end
scenetree={findObject=function(name)
  assert(name=='PostFxSSSRObject');queries=queries+1
  if lookupFailure then error('lookup failed')end
  return object
end}
settings={getValue=function()settingsReads=settingsReads+1;error('must not read settings')end,
  setValue=function()settingsWrites=settingsWrites+1;error('must not write settings')end}
function createObject()creates=creates+1;error('must not create objects')end
'''


class NativeSsrEnhancement(unittest.TestCase):
    def setUp(self):
        self.instances = []

    def tearDown(self):
        for lua in self.instances:
            for counter in ('settingsReads', 'settingsWrites', 'creates', 'deletes',
                            'enableCalls', 'disableCalls'):
                self.assertEqual(lua.globals()[counter], 0, counter)

    def runtimes(self, setup=''):
        for runtime in (Lua51, LuaJIT):
            with self.subTest(runtime=runtime.__module__, setup=setup):
                lua = runtime(unpack_returned_tuples=True)
                lua.execute(MOCK)
                if setup:
                    lua.execute(setup)
                module = lua.execute(SOURCE)
                self.instances.append(lua)
                yield lua, module

    def test_load_and_inactive_update_do_not_query_or_mutate_native_state(self):
        for lua, module in self.runtimes():
            self.assertEqual(lua.globals().queries, 0)
            for _ in range(100):
                self.assertTrue(module.update()[0])
            self.assertEqual(lua.globals().queries, 0)
            self.assertEqual(lua.globals().writes, 0)
            state = module.getStatus()
            self.assertFalse(state.requested)
            self.assertFalse(state.denseTracingActive)
            self.assertEqual(state.currentSamplesPerQuad, 1)
            self.assertIsNone(state.baselineSamplesPerQuad)
            self.assertFalse(state.gameAppearanceVerified)
            self.assertFalse(state.performanceVerified)
            self.assertIn('not four samples per pixel', state.samplingMeaning)

    def test_enable_dense_tracing_retains_original_baseline(self):
        for baseline in (1, 2):
            for lua, module in self.runtimes('object.value=' + repr(str(baseline))):
                ok, state = module.enable()
                self.assertTrue(ok)
                self.assertTrue(state.requested)
                self.assertTrue(state.denseTracingActive)
                self.assertTrue(state.ownsField)
                self.assertFalse(state.restorePending)
                self.assertEqual(state.currentSamplesPerQuad, 4)
                self.assertEqual(state.baselineSamplesPerQuad, baseline)
                self.assertEqual(state.objectId, 42)
                self.assertEqual(state.objectClass, 'PostFxSSSR')
                self.assertTrue(state.nativeEnabled)
                self.assertEqual(lua.globals().writes, 1)

    def test_baseline_already_four_is_truthful_and_requires_no_writes(self):
        for lua, module in self.runtimes("object.value='4'"):
            ok, state = module.enable()
            self.assertTrue(ok)
            self.assertTrue(state.baselineSameAsEnhanced)
            self.assertTrue(state.denseTracingActive)
            self.assertFalse(state.ownsField)
            self.assertIn('already', state.restoration)
            self.assertTrue(module.setComparisonMode('native')[0])
            self.assertFalse(module.getStatus().denseTracingActive)
            self.assertTrue(module.setComparisonMode('enhanced')[0])
            self.assertTrue(module.getStatus().denseTracingActive)
            self.assertTrue(module.disable()[0])
            self.assertEqual(lua.globals().writes, 0)

    def test_enable_and_update_are_idempotent(self):
        for lua, module in self.runtimes():
            for _ in range(20):
                self.assertTrue(module.enable()[0])
                self.assertTrue(module.update()[0])
            self.assertEqual(lua.globals().writes, 1)
            self.assertTrue(module.disable()[0])
            self.assertTrue(module.disable()[0])
            self.assertEqual(lua.globals().writes, 2)

    def test_full_frame_native_enhanced_comparison_restores_and_reapplies(self):
        for lua, module in self.runtimes():
            self.assertTrue(module.enable()[0])
            self.assertTrue(module.setComparisonMode('native')[0])
            state = module.getStatus()
            self.assertTrue(state.requested)
            self.assertEqual(state.comparisonMode, 'native')
            self.assertEqual(state.currentSamplesPerQuad, 1)
            self.assertFalse(state.denseTracingActive)
            self.assertFalse(state.ownsField)
            for _ in range(5):
                self.assertTrue(module.update()[0])
            self.assertTrue(module.setComparisonMode('native')[0])
            self.assertEqual(lua.globals().writes, 2)
            self.assertTrue(module.setComparisonMode('enhanced')[0])
            self.assertEqual(module.getStatus().currentSamplesPerQuad, 4)
            self.assertTrue(module.disable('finished comparison')[0])
            self.assertEqual(lua.globals().object.value, '1')
            self.assertEqual(lua.globals().writes, 4)

    def test_comparison_requires_active_session_and_rejects_unknown_modes(self):
        for lua, module in self.runtimes():
            self.assertFalse(module.setComparisonMode('native')[0])
            self.assertFalse(module.setComparisonMode('enhanced')[0])
            self.assertTrue(module.enable()[0])
            for value in (None, '', 'NATIVE', 'split', False, 1):
                self.assertFalse(module.setComparisonMode(value)[0])
            self.assertEqual(module.getStatus().comparisonMode, 'enhanced')
            self.assertEqual(lua.globals().writes, 1)

    def test_unsupported_sample_values_are_not_written(self):
        for value in ('0', '3', '1.5', '-1', 'nan', 'inf', 'invalid', ''):
            for lua, module in self.runtimes('object.value=' + repr(value)):
                self.assertFalse(module.enable()[0])
                self.assertEqual(lua.globals().writes, 0)
                self.assertFalse(module.getStatus().requested)

    def test_native_disabled_is_not_enabled_by_enhancement(self):
        for lua, module in self.runtimes('object.enabled=false'):
            ok, why = module.enable()
            self.assertFalse(ok)
            self.assertIn('Enable native', why)
            self.assertFalse(module.getStatus().nativeEnabled)
            self.assertEqual(lua.globals().writes, 0)

    def test_unknown_native_enabled_state_fails_closed(self):
        for value in ('nil', '0', "'true'", '1', '{}'):
            for lua, module in self.runtimes('object.enabled=' + value):
                self.assertFalse(module.enable()[0])
                self.assertEqual(lua.globals().writes, 0)

    def test_missing_wrong_class_invalid_identity_and_static_metadata_refuse(self):
        setups = ('object=nil', "object.class='PostEffect'", "object.id='42'", 'object.id=0',
                  'object.id=-1', 'object.id=1.5', 'object.id=0/0', 'object.id=1/0',
                  'object.fields={}', 'object.fields=nil', 'object.metadataFailure=true',
                  'lookupFailure=true', 'object.readFailure=true', 'object.enabledFailure=true',
                  'object.value=true')
        for setup in setups:
            for lua, module in self.runtimes(setup):
                self.assertFalse(module.enable()[0])
                self.assertEqual(lua.globals().writes, 0)

    def test_missing_and_throwing_engine_methods_refuse_without_writing(self):
        for setup in ('scenetree=nil', 'scenetree={}', 'object.getID=nil', 'object.getFields=nil',
                      'object.getClassName=nil', 'object.isEnabled=nil', 'object.getField=nil'):
            for lua, module in self.runtimes(setup):
                self.assertFalse(module.enable()[0])
                self.assertEqual(lua.globals().writes, 0)

    def test_external_field_change_stops_without_forced_reclaim(self):
        for lua, module in self.runtimes():
            self.assertTrue(module.enable()[0])
            lua.execute("object.value='2'")
            self.assertFalse(module.update()[0])
            state = module.getStatus()
            self.assertFalse(state.requested)
            self.assertFalse(state.restorePending)
            self.assertIn('externally', state.restoration)
            self.assertEqual(lua.globals().object.value, '2')
            self.assertEqual(lua.globals().writes, 1)
            self.assertTrue(module.disable()[0])
            self.assertEqual(lua.globals().writes, 1)
            self.assertTrue(module.enable()[0])  # Explicit new baseline, not automatic reclaim.
            self.assertEqual(module.getStatus().baselineSamplesPerQuad, 2)
            self.assertTrue(module.disable()[0])
            self.assertEqual(lua.globals().object.value, '2')

    def test_invalid_external_value_is_preserved_too(self):
        for lua, module in self.runtimes():
            self.assertTrue(module.enable()[0])
            lua.execute("object.value='invalid'")
            self.assertFalse(module.update()[0])
            self.assertEqual(lua.globals().object.value, 'invalid')
            self.assertEqual(lua.globals().writes, 1)
            self.assertFalse(module.getStatus().restorePending)

    def test_native_off_restores_owned_field_without_changing_enablement(self):
        for lua, module in self.runtimes():
            self.assertTrue(module.enable()[0])
            lua.execute('object.enabled=false')
            self.assertFalse(module.update()[0])
            self.assertFalse(module.getStatus().requested)
            self.assertFalse(lua.globals().object.enabled)
            self.assertEqual(lua.globals().object.value, '1')
            self.assertEqual(lua.globals().writes, 2)

    def test_native_off_during_write_is_not_accepted_as_success(self):
        for lua, module in self.runtimes('object.nativeOffOnWrite=true'):
            self.assertFalse(module.enable()[0])
            self.assertFalse(module.getStatus().requested)
            self.assertFalse(lua.globals().object.enabled)
            self.assertEqual(lua.globals().object.value, '1')
            self.assertEqual(lua.globals().writes, 2)

    def test_replacement_even_with_reused_id_is_never_modified(self):
        for lua, module in self.runtimes():
            self.assertTrue(module.enable()[0])
            lua.execute("original=object;object=newObject(42,'2')")
            self.assertFalse(module.update()[0])
            state = module.getStatus()
            self.assertFalse(state.requested)
            self.assertFalse(state.restorePending)
            self.assertIn('replacement left untouched', state.restoration)
            self.assertEqual(lua.globals().original.value, '4')
            self.assertEqual(lua.globals().object.value, '2')
            self.assertEqual(lua.globals().writes, 1)
            self.assertTrue(module.enable()[0])
            self.assertEqual(module.getStatus().baselineSamplesPerQuad, 2)
            self.assertTrue(module.disable()[0])
            self.assertEqual(lua.globals().object.value, '2')

    def test_absent_owner_is_retired_not_claimed_restored(self):
        for lua, module in self.runtimes():
            self.assertTrue(module.enable()[0])
            lua.execute('original=object;object=nil')
            self.assertFalse(module.update()[0])
            state = module.getStatus()
            self.assertFalse(state.restorePending)
            self.assertIn('retired, not restored', state.restoration)
            self.assertEqual(lua.globals().writes, 1)
            self.assertTrue(module.disable()[0])

    def test_throw_before_write_and_false_setter_do_not_orphan_ownership(self):
        for mode in ('throw-before', 'false-before'):
            for lua, module in self.runtimes('object.enhanceMode=' + repr(mode)):
                self.assertFalse(module.enable()[0])
                state = module.getStatus()
                self.assertFalse(state.requested)
                self.assertFalse(state.restorePending)
                self.assertFalse(state.ownsField)
                self.assertEqual(lua.globals().object.value, '1')
                self.assertEqual(lua.globals().writes, 1)

    def test_throw_after_write_rolls_back_and_verifies_baseline(self):
        for lua, module in self.runtimes("object.enhanceMode='throw-after'"):
            self.assertFalse(module.enable()[0])
            state = module.getStatus()
            self.assertFalse(state.requested)
            self.assertFalse(state.restorePending)
            self.assertEqual(lua.globals().object.value, '1')
            self.assertEqual(lua.globals().writes, 2)
            self.assertIn('restored and verified', state.restoration)

    def test_clamped_write_is_not_accepted_as_dense_tracing(self):
        for lua, module in self.runtimes("object.enhanceMode='clamp'"):
            ok, why = module.enable()
            self.assertFalse(ok)
            self.assertIn('exact readback', why)
            self.assertFalse(module.getStatus().denseTracingActive)
            self.assertEqual(lua.globals().object.value, '1')
            self.assertEqual(lua.globals().writes, 2)

    def test_failed_restore_retains_ledger_and_requires_explicit_retry(self):
        for lua, module in self.runtimes():
            self.assertTrue(module.enable()[0])
            lua.execute("object.restoreMode='throw-before'")
            self.assertFalse(module.disable('test disable')[0])
            state = module.getStatus()
            self.assertTrue(state.restorePending)
            self.assertTrue(state.ownsField)
            self.assertFalse(state.requested)
            self.assertEqual(lua.globals().object.value, '4')
            queries, writes = lua.globals().queries, lua.globals().writes
            for _ in range(20):
                self.assertFalse(module.update()[0])
            self.assertEqual(lua.globals().queries, queries)
            self.assertEqual(lua.globals().writes, writes)
            self.assertFalse(module.enable()[0])
            self.assertEqual(lua.globals().queries, queries)
            lua.execute('object.restoreMode=nil')
            self.assertTrue(module.disable('explicit retry')[0])
            self.assertFalse(module.getStatus().restorePending)
            self.assertEqual(lua.globals().object.value, '1')

    def test_failed_post_write_readback_retains_uncertain_ownership(self):
        for lua, module in self.runtimes('object.afterWriteReadFailure=true'):
            self.assertFalse(module.enable()[0])
            state = module.getStatus()
            self.assertTrue(state.restorePending)
            self.assertTrue(state.ownsField)
            self.assertFalse(state.requested)
            self.assertEqual(lua.globals().object.value, '4')
            self.assertEqual(lua.globals().writes, 1)
            lua.execute('object.afterWriteReadFailure=false')
            self.assertTrue(module.disable('readback recovered')[0])
            self.assertEqual(lua.globals().object.value, '1')
            self.assertEqual(lua.globals().writes, 2)

    def test_read_failure_on_disable_does_not_blindly_restore(self):
        for lua, module in self.runtimes():
            self.assertTrue(module.enable()[0])
            lua.execute('object.readFailure=true')
            self.assertFalse(module.disable()[0])
            self.assertTrue(module.getStatus().restorePending)
            self.assertEqual(lua.globals().writes, 1)
            lua.execute("object.value='2';object.readFailure=false")
            self.assertTrue(module.disable('external value discovered')[0])
            self.assertEqual(lua.globals().object.value, '2')
            self.assertFalse(module.getStatus().restorePending)
            self.assertEqual(lua.globals().writes, 1)

    def test_comparison_restore_failure_stops_and_retains_ledger(self):
        for lua, module in self.runtimes():
            self.assertTrue(module.enable()[0])
            lua.execute("object.restoreMode='throw-before'")
            self.assertFalse(module.setComparisonMode('native')[0])
            state = module.getStatus()
            self.assertFalse(state.requested)
            self.assertTrue(state.restorePending)
            lua.execute('object.restoreMode=nil')
            self.assertTrue(module.disable()[0])
            self.assertEqual(lua.globals().object.value, '1')

    def test_external_change_during_native_comparison_is_not_reclaimed(self):
        for lua, module in self.runtimes():
            self.assertTrue(module.enable()[0])
            self.assertTrue(module.setComparisonMode('native')[0])
            lua.execute("object.value='2'")
            self.assertFalse(module.setComparisonMode('enhanced')[0])
            self.assertEqual(lua.globals().object.value, '2')
            self.assertEqual(lua.globals().writes, 2)
            self.assertFalse(module.getStatus().requested)

    def test_replacement_during_setter_is_not_followed_for_rollback(self):
        for lua, module in self.runtimes('object.replaceOnWrite=true;original=object'):
            self.assertFalse(module.enable()[0])
            self.assertEqual(lua.globals().original.value, '4')
            self.assertEqual(lua.globals().object.value, '2')
            self.assertEqual(lua.globals().writes, 1)
            self.assertFalse(module.getStatus().restorePending)
            self.assertIn('restoration unconfirmed', module.getStatus().restoration)

    def test_throw_after_successful_restore_is_verified_as_restored(self):
        for lua, module in self.runtimes():
            self.assertTrue(module.enable()[0])
            lua.execute("object.restoreMode='throw-after'")
            self.assertTrue(module.disable()[0])
            self.assertEqual(lua.globals().object.value, '1')
            self.assertFalse(module.getStatus().restorePending)
            self.assertIn('restored and verified', module.getStatus().restoration)

    def test_unknown_enabled_state_retains_ledger_for_retry_without_writes(self):
        for lua, module in self.runtimes():
            self.assertTrue(module.enable()[0])
            lua.execute('object.enabledFailure=true')
            self.assertFalse(module.update()[0])
            self.assertTrue(module.getStatus().restorePending)
            self.assertEqual(lua.globals().writes, 1)
            lua.execute('object.enabledFailure=false')
            self.assertTrue(module.disable()[0])
            self.assertEqual(lua.globals().object.value, '1')

    def test_resolution_divisor_is_inventory_only_and_optional(self):
        for setup, expected in (('', 2), ('object.fields.resolutionDivisor=nil', None),
                                ('object.divisorFailure=true', None), ("object.divisor='nan'", None)):
            for lua, module in self.runtimes(setup):
                self.assertEqual(module.getStatus().resolutionDivisor, expected)
                self.assertTrue(module.enable()[0])
                self.assertTrue(module.disable()[0])
                self.assertEqual(lua.globals().object.divisor, 'nan' if "'nan'" in setup else '2')
                self.assertEqual(lua.globals().writes, 2)

    def test_status_is_an_independent_snapshot_not_a_mutable_ledger(self):
        for lua, module in self.runtimes():
            self.assertTrue(module.enable()[0])
            state = module.getStatus()
            state.requested = False
            state.baselineSamplesPerQuad = 4
            state.objectId = 999
            self.assertTrue(module.getStatus().requested)
            self.assertEqual(module.getStatus().baselineSamplesPerQuad, 1)
            self.assertEqual(module.getStatus().objectId, 42)
            self.assertTrue(module.disable()[0])
            self.assertEqual(lua.globals().object.value, '1')

    def test_status_observation_never_reclaims_or_stops_a_session(self):
        for lua, module in self.runtimes():
            self.assertTrue(module.enable()[0])
            lua.execute("object.value='2'")
            state = module.getStatus()
            self.assertTrue(state.requested)
            self.assertFalse(state.denseTracingActive)
            self.assertEqual(lua.globals().writes, 1)
            self.assertFalse(module.update()[0])
            self.assertFalse(module.getStatus().requested)

    def test_typed_only_binding_ignores_static_metadata_and_dynamic_decoy(self):
        for lua, module in self.runtimes("mt=makeTyped();object.value='4';object.metadataFailure=true"):
            self.assertTrue(module.enable()[0])
            state = module.getStatus()
            self.assertEqual(state.accessKind, 'typed')
            self.assertEqual(state.ownedAccessKind, 'typed')
            self.assertEqual(state.baselineSamplesPerQuad, 1)
            self.assertEqual(state.currentSamplesPerQuad, 4)
            self.assertEqual(state.resolutionDivisor, 2)
            self.assertTrue(state.denseTracingActive)
            self.assertEqual(lua.globals().fieldReads, 0)
            self.assertEqual(lua.globals().fieldWrites, 0)
            self.assertEqual(lua.globals().typedWrites, 1)
            self.assertTrue(module.disable()[0])
            self.assertEqual(lua.globals().object.nativeValue, 1)
            self.assertEqual(lua.globals().object.value, '4')
            self.assertEqual(lua.globals().fieldWrites, 0)

    def test_typed_path_does_not_require_generic_field_methods(self):
        for lua, module in self.runtimes('makeTyped();object.getField=nil;object.setField=nil;object.getFields=nil'):
            self.assertTrue(module.enable()[0])
            self.assertTrue(module.disable()[0])
            self.assertEqual(lua.globals().object.nativeValue, 1)
            self.assertEqual(lua.globals().fieldWrites, 0)

    def test_typed_comparison_and_already_dense_baseline(self):
        for baseline in (1, 2, 4):
            for lua, module in self.runtimes('makeTyped();object.nativeValue=' + str(baseline)):
                self.assertTrue(module.enable()[0])
                self.assertEqual(module.getStatus().baselineSamplesPerQuad, baseline)
                self.assertEqual(module.getStatus().baselineSameAsEnhanced, baseline == 4)
                self.assertTrue(module.setComparisonMode('native')[0])
                self.assertEqual(lua.globals().object.nativeValue, baseline)
                self.assertTrue(module.setComparisonMode('enhanced')[0])
                self.assertEqual(lua.globals().object.nativeValue, 4)
                self.assertTrue(module.disable()[0])
                self.assertEqual(lua.globals().object.nativeValue, baseline)
                self.assertEqual(lua.globals().fieldWrites, 0)
                self.assertEqual(lua.globals().typedWrites, 0 if baseline == 4 else 4)

    def test_incomplete_or_shadowed_typed_pair_never_falls_back_to_static(self):
        setups = ('mt[1].samplesPerQuad=nil', 'mt[2].samplesPerQuad=nil',
                  'mt[1].samplesPerQuad=false', 'mt[2].samplesPerQuad=false',
                  "mt.samplesPerQuad='shadow'", 'mt[1]=false', 'mt[2]=false')
        for setup in setups:
            for lua, module in self.runtimes('mt=makeTyped();object.fields.samplesPerQuad={};' + setup):
                ok, why = module.enable()
                self.assertFalse(ok)
                self.assertNotIn('[string', why)
                self.assertEqual(lua.globals().writes, 0)
                self.assertEqual(lua.globals().fieldReads, 0)

    def test_invalid_typed_getter_is_called_once_without_generic_fallback(self):
        for value in ('nil', 'false', "'1'", '0/0', '1/0', '3', '1.5'):
            for lua, module in self.runtimes('makeTyped();object.nativeValue=' + value):
                self.assertFalse(module.enable()[0])
                self.assertEqual(lua.globals().typedReads, 1)
                self.assertEqual(lua.globals().fieldReads, 0)
                self.assertEqual(lua.globals().writes, 0)
        for lua, module in self.runtimes('makeTyped();object.readFailure=true'):
            self.assertFalse(module.enable()[0])
            self.assertEqual(lua.globals().typedReads, 1)
            self.assertEqual(lua.globals().writes, 0)

    def test_typed_setter_failures_rollback_only_through_registered_setter(self):
        for mode, expected_writes in (('throw-before', 1), ('false-before', 1),
                                      ('throw-after', 2), ('clamp', 2)):
            for lua, module in self.runtimes('makeTyped();object.enhanceMode=' + repr(mode)):
                self.assertFalse(module.enable()[0])
                self.assertEqual(lua.globals().object.nativeValue, 1)
                self.assertEqual(lua.globals().typedWrites, expected_writes)
                self.assertEqual(lua.globals().fieldWrites, 0)
                self.assertFalse(module.getStatus().restorePending)

    def test_typed_failed_restore_retains_original_access_for_explicit_retry(self):
        for lua, module in self.runtimes('makeTyped()'):
            self.assertTrue(module.enable()[0])
            lua.execute("object.restoreMode='throw-before'")
            self.assertFalse(module.disable()[0])
            self.assertTrue(module.getStatus().restorePending)
            self.assertFalse(module.enable()[0])
            lua.execute('object.restoreMode=nil')
            self.assertTrue(module.disable()[0])
            self.assertEqual(lua.globals().object.nativeValue, 1)
            self.assertEqual(lua.globals().fieldWrites, 0)

    def test_typed_external_native_value_change_is_preserved(self):
        for lua, module in self.runtimes('makeTyped()'):
            self.assertTrue(module.enable()[0])
            lua.execute('object.nativeValue=2')
            self.assertFalse(module.update()[0])
            self.assertFalse(module.getStatus().restorePending)
            self.assertEqual(lua.globals().object.nativeValue, 2)
            self.assertEqual(lua.globals().typedWrites, 1)
            self.assertEqual(lua.globals().fieldWrites, 0)

    def test_same_object_binding_replacements_are_pending_not_new_setter_calls(self):
        changes = ('mt[1].samplesPerQuad=function(self)return self.nativeValue end',
                   'mt[2].samplesPerQuad=replacementSetter',
                   'setmetatable(object,{[1]=mt[1],[2]=mt[2]})',
                   'mt[2].samplesPerQuad=nil', 'mt.samplesPerQuad=4')
        for change in changes:
            for lua, module in self.runtimes('''
              mt=makeTyped();originalGetter=mt[1].samplesPerQuad;originalSetter=mt[2].samplesPerQuad
              replacementCalls=0;replacementSetter=function()replacementCalls=replacementCalls+1 end
            '''):
                self.assertTrue(module.enable()[0])
                lua.execute(change)
                self.assertFalse(module.update()[0])
                state = module.getStatus()
                self.assertFalse(state.requested)
                self.assertTrue(state.restorePending)
                self.assertFalse(state.denseTracingActive)
                self.assertFalse(module.disable()[0])
                self.assertEqual(lua.globals().replacementCalls, 0)
                self.assertEqual(lua.globals().typedWrites, 1)
                self.assertEqual(lua.globals().fieldWrites, 0)
                lua.execute('mt[1].samplesPerQuad=originalGetter;mt[2].samplesPerQuad=originalSetter;mt.samplesPerQuad=nil;setmetatable(object,mt)')
                self.assertTrue(module.disable()[0])
                self.assertEqual(lua.globals().object.nativeValue, 1)

    def test_binding_change_between_observation_and_write_refuses_new_setter(self):
        for lua, module in self.runtimes('''
          mt=makeTyped();originalSetter=mt[2].samplesPerQuad;replacementCalls=0
          object.replacementSetter=function()replacementCalls=replacementCalls+1 end
          object.changeBindingOnRead=true
        '''):
            self.assertFalse(module.enable()[0])
            self.assertTrue(module.getStatus().restorePending)
            self.assertEqual(lua.globals().replacementCalls, 0)
            self.assertEqual(lua.globals().writes, 0)
            lua.execute('object.changeBindingOnRead=false;mt[2].samplesPerQuad=originalSetter')
            self.assertTrue(module.disable()[0])
            self.assertEqual(lua.globals().object.nativeValue, 1)

    def test_binding_change_during_setter_retains_pending_original_ownership(self):
        for lua, module in self.runtimes('''
          mt=makeTyped();originalSetter=mt[2].samplesPerQuad;replacementCalls=0
          object.replacementSetter=function()replacementCalls=replacementCalls+1 end
          object.replaceSetterOnWrite=true
        '''):
            self.assertFalse(module.enable()[0])
            self.assertTrue(module.getStatus().restorePending)
            self.assertFalse(module.disable()[0])
            self.assertEqual(lua.globals().replacementCalls, 0)
            self.assertEqual(lua.globals().object.nativeValue, 4)
            self.assertEqual(lua.globals().typedWrites, 1)
            lua.execute('object.replaceSetterOnWrite=false;mt[2].samplesPerQuad=originalSetter')
            self.assertTrue(module.disable()[0])
            self.assertEqual(lua.globals().object.nativeValue, 1)

    def test_object_replaced_by_getter_is_rechecked_before_first_write(self):
        for lua, module in self.runtimes('makeTyped();original=object;object.replaceObjectOnRead=true'):
            self.assertFalse(module.enable()[0])
            self.assertEqual(lua.globals().writes, 0)
            self.assertEqual(lua.globals().typedWrites, 0)
            self.assertEqual(lua.globals().fieldWrites, 0)
            self.assertEqual(lua.globals().original.nativeValue, 1)
            self.assertEqual(lua.globals().object.value, '2')
            self.assertFalse(module.getStatus().restorePending)

    def test_object_replaced_by_static_metadata_is_not_written_through_stale_ref(self):
        for lua, module in self.runtimes('''
          original=object
          function object:getFields()object=newObject(42,'2');return self.fields end
        '''):
            self.assertFalse(module.enable()[0])
            self.assertEqual(lua.globals().writes, 0)
            self.assertEqual(lua.globals().original.value, '1')
            self.assertEqual(lua.globals().object.value, '2')

    def test_static_access_stays_supported_without_any_typed_entries(self):
        for lua, module in self.runtimes('setmetatable(object,{[1]={},[2]={}})'):
            self.assertTrue(module.enable()[0])
            self.assertEqual(module.getStatus().accessKind, 'static')
            self.assertTrue(module.disable()[0])
            self.assertEqual(lua.globals().fieldWrites, 2)
            self.assertEqual(lua.globals().typedWrites, 0)

    def test_inspect_reports_typed_static_and_dynamic_paths_without_mutation(self):
        for lua, module in self.runtimes("mt=makeTyped();object.value='4'"):
            detail = module.inspect()
            self.assertTrue(detail.readOnly)
            self.assertTrue(detail.objectPresent)
            self.assertEqual(detail.objectId, 42)
            self.assertEqual(detail.objectClass, 'PostFxSSSR')
            self.assertTrue(detail.nativeEnabled)
            self.assertEqual(detail.accessKind, 'typed')
            prop = detail.properties.samplesPerQuad
            self.assertFalse(prop.staticAdvertised)
            self.assertTrue(prop.dynamicAdvertised)
            self.assertTrue(prop.typedGetterPresent)
            self.assertTrue(prop.typedSetterPresent)
            self.assertEqual(prop.typedRead.value, 1)
            self.assertEqual(prop.typedRead.valueType, 'number')
            self.assertEqual(prop.fieldRead.value, '4')
            self.assertEqual(detail.properties.resolutionDivisor.typedRead.value, 2)
            self.assertEqual(lua.globals().writes, 0)
            self.assertFalse(module.getStatus().requested)

    def test_inspect_handles_missing_protected_and_throwing_metadata(self):
        for setup in ('object=nil', 'lookupFailure=true',
                      "setmetatable(object,{__metatable='protected'})", 'object.metadataFailure=true',
                      'mt=makeTyped();object.readFailure=true', 'object.getID=nil',
                      'scenetree=nil', 'object.enabledFailure=true'):
            for lua, module in self.runtimes(setup):
                detail = module.inspect()
                self.assertTrue(detail.readOnly)
                self.assertEqual(lua.globals().writes, 0)
                self.assertFalse(module.getStatus().requested)

    def test_inspect_marks_readonly_shadowed_and_invalid_typed_entries(self):
        for setup in ('mt[2].samplesPerQuad=nil', "mt.samplesPerQuad='shadow'", 'mt[1].samplesPerQuad=false'):
            for lua, module in self.runtimes('mt=makeTyped();' + setup):
                detail = module.inspect()
                self.assertEqual(detail.accessKind, 'unavailable')
                self.assertEqual(lua.globals().writes, 0)
                if 'shadow' in setup:
                    self.assertTrue(detail.properties.samplesPerQuad.rawMemberShadow)
                if 'false' in setup:
                    self.assertEqual(detail.properties.samplesPerQuad.getterEntryType, 'boolean')

    def test_inspect_cpu_status_results_are_bounded_plain_copies(self):
        for lua, module in self.runtimes('''
          makeTyped();cpuReads=0;sourceStatus={text=string.rep('x',3000),nested={a={b={c='deep'}}}}
          for i=1,30 do sourceStatus['item'..i]=i end
          function object:getStatus()cpuReads=cpuReads+1;return string.rep('x',3000)end
          function object:getDenoiserStatus()cpuReads=cpuReads+1;return sourceStatus end
          function object:getSurfaceStatus()cpuReads=cpuReads+1;error('unavailable status',0)end
        '''):
            detail = module.inspect()
            self.assertEqual(lua.globals().cpuReads, 3)
            self.assertEqual(len(detail.nativeStatus.getStatus.value), 1024)
            self.assertTrue(detail.nativeStatus.getDenoiserStatus.value.truncated)
            self.assertLessEqual(len(list(detail.nativeStatus.getDenoiserStatus.value.keys())), 17)
            self.assertFalse(detail.nativeStatus.getSurfaceStatus.ok)
            detail.nativeStatus.getDenoiserStatus.value.text = 'caller mutation'
            self.assertNotEqual(lua.globals().sourceStatus.text, 'caller mutation')
            self.assertEqual(lua.globals().writes, 0)

    def test_expected_access_errors_do_not_contain_lua_file_prefixes(self):
        for lua, module in self.runtimes('object.fields={}'):
            ok, why = module.enable()
            self.assertFalse(ok)
            self.assertEqual(why, 'Native samplesPerQuad has neither a complete typed binding nor an advertised static field.')
            self.assertNotIn('[string', module.getStatus().observationReason)


if __name__ == '__main__':
    unittest.main(verbosity=2)
