"""Live-material selection and transactional native shadow requests, not GPU proof."""
import unittest
from pathlib import Path
from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT=Path(__file__).resolve().parents[2]
SOURCE=(ROOT/'lua/ge/extensions/beamrt/glassShadowProbe.lua').read_text()
MAIN=(ROOT/'lua/ge/extensions/beamrt/main.lua').read_text()
FIXTURE=r'''
objects={};writes={};playerVehicle={names={'car_glass','car_glass_int','car_body','car_headlight_glass'}}
function playerVehicle:getMeshMaterialNames()return self.names end
be={getPlayerVehicle=function()return playerVehicle end}
scenetree={findObject=function(name)return objects[name]end}
function material(name)
 local m={___type='class<Material>',name=name,filename='/vehicles/car/main.materials.json',reloads=0,
 fields={mapTo=name,translucent='1',alphaTest='0',castShadows='0',activeLayers='1',emissive='0'}}
 function m:getFilename()return self.filename end
 function m:getField(key,index)return self.fields[key]or''end
 function m:setField(key,index,value)
  assert(key=='castShadows' and index==0,'Probe must not change opacity, body or shader fields')
  writes[#writes+1]={self.name,key,value};self.fields[key]=self.canonical and (value=='1'and'true'or'false')or value
  if self.failSet then self.failSet=false;error('Setter threw after write')end
 end
 function m:reload()
  self.reloads=self.reloads+1
  if self.failReload then self.failReload=false;error('Reload failed')end
  if self.failAlways then error('Reload still failing')end
 end
 objects[name]=m;return m
end
material('car_glass');material('car_glass_int');material('car_body');material('car_headlight_glass')
'''


class GlassShadowProbe(unittest.TestCase):
    def runtimes(self):
        for cls in (Lua51,LuaJIT):
            lua=cls(unpack_returned_tuples=True);lua.execute(FIXTURE)
            m=lua.execute(SOURCE);lua.globals().probe=m
            yield lua,m

    def test_default_off_and_inspection_read_only(self):
        for lua,m in self.runtimes():
            m.update();self.assertFalse(m.getStatus().enabled)
            self.assertTrue(m.inspect()[0]);status=m.getStatus()
            self.assertEqual(list(status.candidates.values()),['car_glass','car_glass_int'])
            self.assertEqual(status.inspected,4);self.assertEqual(len(lua.globals().writes),0)
            self.assertFalse(status.partialTransmissionImplemented)
            self.assertFalse(status.tintedShadowsImplemented)
            self.assertFalse(status.gpuExecutionVerified)

    def test_only_shadow_eligibility_changes_and_idempotent_restore(self):
        for lua,m in self.runtimes():
            self.assertTrue(m.enable()[0]);self.assertTrue(m.enable()[0]);m.update()
            self.assertEqual(len(lua.globals().writes),2)
            self.assertEqual(m.getStatus().owned,2)
            self.assertEqual(lua.globals().objects.car_body.fields.castShadows,'0')
            self.assertEqual(lua.globals().objects.car_headlight_glass.fields.castShadows,'0')
            self.assertEqual(lua.globals().objects.car_glass.fields.translucent,'1')
            self.assertFalse(m.inspect()[0])
            self.assertTrue(m.disable()[0]);self.assertTrue(m.disable()[0])
            self.assertEqual(lua.globals().objects.car_glass.fields.castShadows,'0')
            self.assertEqual(len(lua.globals().writes),4)

    def test_unsafe_identity_flags_paths_and_lenses_rejected(self):
        mutations=("m.filename='/levels/test/materials.json'", "m.___type='class<CustomMaterial>'",
                   "m.fields.mapTo='other'", "m.fields.translucent='0'", "m.fields.alphaTest='1'",
                   "m.fields.alphaTest=''", "m.fields.castShadows=''", "m.fields.emissive='1'",
                   "m.fields.activeLayers='2'")
        for lua,m in self.runtimes():
            for mutation in mutations:
                lua.execute("objects={};playerVehicle.names={'car_glass'};local m=material('car_glass');"+mutation)
                self.assertFalse(m.enable()[0],mutation)
                self.assertEqual(len(lua.globals().writes),0)

    def test_native_class_fallback_and_boolean_canonicalization(self):
        for lua,m in self.runtimes():
            lua.execute("local m=objects.car_glass;m.___type=nil;m.getClassName=function()return 'Material'end;m.canonical=true;m.fields.castShadows='false'")
            self.assertTrue(m.enable()[0]);m.update();self.assertTrue(m.getStatus().enabled)
            self.assertTrue(m.disable()[0])
            self.assertEqual(lua.globals().objects.car_glass.fields.castShadows,'false')

    def test_existing_native_casters_never_owned_or_reloaded(self):
        for lua,m in self.runtimes():
            lua.execute("objects.car_glass.fields.castShadows='true'")
            self.assertTrue(m.enable()[0]);self.assertEqual(m.getStatus().owned,1)
            m.disable();self.assertEqual(lua.globals().objects.car_glass.reloads,0)
            self.assertEqual(lua.globals().objects.car_glass.fields.castShadows,'true')
            lua.execute("objects.car_glass_int.fields.castShadows='1'")
            self.assertFalse(m.enable()[0]);self.assertFalse(m.getStatus().enabled)
            self.assertIn('already request',m.getStatus().reason)

    def test_throwing_setter_and_reload_rollback_entire_probe(self):
        for lua,m in self.runtimes():
            for failure in ('failSet','failReload'):
                lua.execute("objects.car_glass_int."+failure+"=true")
                self.assertFalse(m.enable()[0]);self.assertFalse(m.getStatus().enabled)
                self.assertEqual(m.getStatus().owned,0)
                self.assertEqual(lua.globals().objects.car_glass.fields.castShadows,'0')
                self.assertEqual(lua.globals().objects.car_glass_int.fields.castShadows,'0')

    def test_canonicalizing_setter_throw_after_write_is_rolled_back(self):
        for lua,m in self.runtimes():
            lua.execute("local m=objects.car_glass;m.canonical=true;m.fields.castShadows='false';m.failSet=true")
            self.assertFalse(m.enable()[0]);self.assertEqual(m.getStatus().owned,0)
            self.assertEqual(lua.globals().objects.car_glass.fields.castShadows,'false')

    def test_failed_restoration_retains_lease_and_requires_retry(self):
        for lua,m in self.runtimes():
            self.assertTrue(m.enable()[0]);lua.execute('objects.car_glass.failAlways=true')
            self.assertFalse(m.disable()[0]);self.assertEqual(m.getStatus().pendingRestore,1)
            self.assertFalse(m.enable()[0]);self.assertFalse(m.inspect()[0])
            lua.execute('objects.car_glass.failAlways=false')
            self.assertTrue(m.disable()[0]);self.assertEqual(m.getStatus().pendingRestore,0)
            self.assertTrue(m.enable()[0])

    def test_material_replacement_and_external_edits_not_overwritten(self):
        for lua,m in self.runtimes():
            m.enable();lua.execute("material('car_glass');objects.car_glass_int.fields.castShadows='false';writes={}")
            m.update();self.assertFalse(m.getStatus().enabled)
            self.assertEqual(len(lua.globals().writes),0)
            self.assertEqual(lua.globals().objects.car_glass_int.fields.castShadows,'false')
            self.assertEqual(m.getStatus().owned,0)

    def test_vehicle_switch_and_material_semantic_change_restore(self):
        for lua,m in self.runtimes():
            m.enable();lua.execute('previousVehicle=playerVehicle;playerVehicle=nil')
            m.update();self.assertFalse(m.getStatus().enabled)
            self.assertEqual(lua.globals().objects.car_glass.fields.castShadows,'0')
            lua.execute("playerVehicle=previousVehicle")
            m.enable();lua.execute("objects.car_glass.fields.translucent='0'")
            m.update();self.assertFalse(m.getStatus().enabled)
            self.assertEqual(lua.globals().objects.car_glass.fields.castShadows,'0')
            self.assertEqual(lua.globals().objects.car_glass.fields.translucent,'0')

    def test_missing_vehicle_duplicate_names_and_bounded_scan(self):
        for lua,m in self.runtimes():
            lua.execute('previousVehicle=playerVehicle;playerVehicle=nil')
            self.assertFalse(m.enable()[0]);self.assertEqual(len(lua.globals().writes),0)
            lua.execute("playerVehicle=previousVehicle;playerVehicle.names={'car_glass','car_glass'}")
            self.assertTrue(m.enable()[0]);self.assertEqual(m.getStatus().owned,1);m.disable()
            lua.execute("writes={};playerVehicle.names={};for i=1,513 do playerVehicle.names[i]='car_glass'end")
            self.assertFalse(m.enable()[0]);self.assertEqual(len(lua.globals().writes),0)
            self.assertEqual(len(m.getStatus().candidates),0)

    def test_status_is_not_mutable_internal_candidate_list(self):
        for lua,m in self.runtimes():
            m.inspect();status=m.getStatus();status.candidates[1]='car_body'
            self.assertEqual(m.getStatus().candidates[1],'car_glass')

    def test_main_wires_restore_lifecycle_without_automatic_activation(self):
        for hook in ('onSettingsChanged','onClientStartMission','onClientEndMission','onExtensionUnloaded'):
            body=MAIN.split('function M.'+hook+'(',1)[1].split('\nfunction M.',1)[0]
            self.assertIn("M._glassShadowProbe.disable(",body)
        self.assertIn('M._glassShadowProbe.update()',MAIN)
        self.assertIn("previous.disable,'BeamRT reloaded'",MAIN)
        self.assertIn('Try native window shadows##BeamRTGlass',MAIN)
        self.assertIn('Retry window restoration##BeamRTGlass',MAIN)
        self.assertNotIn('createObject',SOURCE)
        for forbidden in ('writeFile','jsonWriteFile','reInitMaterials','setMaterialOverride'):
            self.assertNotIn(forbidden,SOURCE)

if __name__=='__main__':unittest.main()
