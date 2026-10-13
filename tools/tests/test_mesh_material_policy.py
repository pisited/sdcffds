"""Real Lua policy with BeamNG Material-wrapper and legacy-class fixtures."""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime

ROOT=Path(__file__).resolve().parents[2]
MOCK=r'''
package.path='lua/?.lua;'..package.path
objects={};scenetree={findObject=function(name)return objects[name]end}
function wrapper(name,tag,fields)
  local o={___type=tag}
  function o:getField(key,index)
    assert(index==0);return fields[key]
  end
  -- No getClassName method, exactly the previously rejected native wrapper.
  objects[name]=o;return o
end
function fields(name)
  return {mapTo=name,alphaTest='0',translucent='0',diffuseColor='1 1 1 1'}
end
wrapper('paint','class<Material>',fields('paint'))
local mask=fields('mask');mask.alphaTest='1';wrapper('mask','class<Material>',mask)
local glass=fields('glass');glass.translucent='1';wrapper('glass','class<Material>',glass)
local faded=fields('faded');faded.diffuseColor='1 1 1 .5';wrapper('faded','class<Material>',faded)
wrapper('incomplete','class<Material>',{mapTo='incomplete',alphaTest='0'})
wrapper('opaque_no_color','class<Material>',{mapTo='opaque_no_color',alphaTest='0',translucent='0'})
wrapper('opaque_rgb_color','class<Material>',{mapTo='opaque_rgb_color',alphaTest='0',translucent='0',diffuseColor='1 1 1'})
wrapper('custom','class<CustomMaterial>',fields('custom'))
wrapper('wrong','class<Material>',fields('other'))
local noshadow=fields('noshadow');noshadow.castShadows='0';wrapper('noshadow','class<Material>',noshadow)
local legacy=wrapper('legacy',nil,fields('legacy'));function legacy:getClassName()return 'Material'end
local deceptive=wrapper('deceptive','class<CustomMaterial>',fields('deceptive'))
function deceptive:getClassName()return 'Material'end
'''

class Policy(unittest.TestCase):
    def setUp(self):
        self.lua=LuaRuntime(unpack_returned_tuples=True);self.lua.execute(MOCK)
        self.module=self.lua.eval("require('ge/extensions/beamrt/meshMaterialPolicy')")
    def capture(self,*names):return self.module.capture(self.lua.table_from(names))
    def test_native_wrapper_without_get_class_name_is_supported(self):
        result=self.capture('paint')
        self.assertEqual(result.opaque,1);self.assertEqual(result.records[1].nativeClass,'Material')
        self.assertEqual(result.records[1].classIdentitySource,'___type')
        self.assertEqual(result.records[1].shadowMode,1)
    def test_alpha_transmission_incomplete_and_mismatched_identity_remain_safe(self):
        result=self.capture('mask','glass','faded','incomplete','wrong','missing')
        self.assertEqual([result.modes[i]for i in range(1,7)],[2,3,3,0,0,0])
        self.assertEqual(result.opaque,0);self.assertFalse(result.alphaTexturesSampled)
        self.assertIn('alphaTest=',result.records[4].reason)
    def test_custom_wrappers_cannot_bypass_type_check(self):
        result=self.capture('custom','deceptive')
        self.assertEqual(result.unknown,2);self.assertEqual(result.opaque,0)
        self.assertIn('CustomMaterial',result.records[1].reason)
    def test_native_no_shadow_declaration_is_separate_from_gi_opacity(self):
        result=self.capture('noshadow');self.assertEqual(result.modes[1],1)
        self.assertEqual(result.records[1].shadowMode,0)
    def test_legacy_api_retained_and_no_field_absence_becomes_opaque(self):
        result=self.capture('legacy','incomplete')
        self.assertEqual(result.modes[1],1);self.assertEqual(result.modes[2],0)
        self.assertEqual(result.records[1].classIdentitySource,'getClassName')
    def test_missing_color_alpha_does_not_override_explicit_opaque_coverage(self):
        result=self.capture('opaque_no_color','opaque_rgb_color','incomplete')
        self.assertEqual([result.modes[i]for i in range(1,4)],[1,1,0])
        self.assertIsNone(result.records[1].fields.colorAlpha)
        self.assertIsNone(result.records[2].fields.colorAlpha)
        self.assertEqual(result.records[1].shadowMode,1)
    def test_observed_guardhouse_flags_no_blanket_opacity_guess(self):
        names=('balustrades','construction','corrugated_modern','curbs','industrial',
               'metal_galvanized','slabs_large','windows_doors_reflective')
        for name in names:
            data=self.lua.table_from({'mapTo':name,'alphaTest':'0','translucent':'0'})
            if name in ('balustrades','construction','industrial','windows_doors_reflective'):data.alphaTest='1'
            if name in ('curbs','slabs_large'):data.translucent='1'
            self.lua.eval('wrapper')(name,'class<Material>',data)
        result=self.capture(*names)
        self.assertEqual((result.opaque,result.masked,result.blended,result.unknown),(2,4,2,0))
        self.assertEqual([result.modes[i]for i in range(1,9)],[2,2,1,3,2,1,3,2])
        self.assertTrue(all(result.records[i].fields.colorAlpha is None for i in range(1,9)))
    def test_all_eight_real_identity_names_use_native_wrapper_path(self):
        names=('balustrades','construction','corrugated_modern','curbs','industrial',
               'metal_galvanized','slabs_large','windows_doors_reflective')
        for name in names:self.lua.eval('wrapper')(name,'class<Material>',self.lua.eval('fields')(name))
        result=self.capture(*names);self.assertEqual(result.opaque,8)
        # This tests the wrapper shape, NOT the real eight materials' opacity.
        self.assertTrue(all(result.records[i].classIdentitySource=='___type'for i in range(1,9)))

if __name__=='__main__':unittest.main(verbosity=2)
