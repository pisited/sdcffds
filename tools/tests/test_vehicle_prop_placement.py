"""Read-only native prop metadata comparisons; synthetic transforms, not GPU proof."""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT=Path(__file__).resolve().parents[2]
SOURCE=(ROOT/'lua/ge/extensions/beamrt/vehiclePropPlacement.lua').read_text()
FIXTURE=r'''
local q=math.sqrt(.5)
origin={100,200,300};nativePosition={x=1,y=2,z=3};nativeRotation={x=0,y=0,z=-q,w=q}
livePosition={x=1,y=2,z=3};liveRotation={x=0,y=0,z=q,w=q}
descriptor={position=nativePosition,rotation=nativeRotation}
record={propmeshes={{nativeIndex=7,meshName='steering'}}}
nativeMesh={propmeshes=function(_,index)assert(index==7);return descriptor end}
matrix={getColumn=function(_,i)assert(i==3);return livePosition end,
 toQuatF=function()return liveRotation end}
requestedPid=nil
vehicle={getID=function()return 42 end,getProp=function(_,pid)
 requestedPid=pid;assert(pid==91);return {getLiveTransformWorld=function()return matrix end}
end}
sourceProps={[0]={mesh='steering',pid=91}}
core_vehicle_manager={getVehicleData=function(id)assert(id==42);return {vdata={props=sourceProps}}end}
function quat(value)return value end
'''


class VehiclePropPlacement(unittest.TestCase):
    def runtimes(self):
        for cls in (Lua51,LuaJIT):
            lua=cls(unpack_returned_tuples=True);lua.execute(FIXTURE)
            module=lua.execute(SOURCE);lua.globals().placement=module
            yield lua,module

    def inspect(self,lua,module):
        g=lua.globals()
        return module.inspect(g.record,g.nativeMesh,g.vehicle,g.origin)

    def test_independent_pid_not_native_index_translation_and_inverse_quaternion(self):
        for lua,m in self.runtimes():
            r=self.inspect(lua,m)
            self.assertTrue(r.comparisonAvailable);self.assertEqual(r.metadataAvailable,1)
            self.assertEqual(r.matched,1);self.assertEqual(lua.globals().requestedPid,91)
            self.assertEqual(r.originRelativeTranslationMaxErrorMetres,0)
            self.assertAlmostEqual(r.worldTranslationMaxErrorMetres,(100**2+200**2+300**2)**.5)
            self.assertEqual(r.orientationAvailable,1)
            self.assertAlmostEqual(r.inverseRotationMaxErrorDegrees,0)
            self.assertAlmostEqual(r.directRotationMaxErrorDegrees,180)
            self.assertFalse(r.propTransformsVerified)
            self.assertFalse(r.details[1].propTransformVerified)
            self.assertIsNone(r.details[1].vertices)

    def test_direct_rotation_sign_equivalence_and_world_translation_alternative(self):
        for lua,m in self.runtimes():
            lua.execute('descriptor.rotation={x=0,y=0,z=-liveRotation.z,w=-liveRotation.w};'
                        'descriptor.position={x=101,y=202,z=303}')
            r=self.inspect(lua,m)
            self.assertAlmostEqual(r.directRotationMaxErrorDegrees,0)
            self.assertAlmostEqual(r.inverseRotationMaxErrorDegrees,180)
            self.assertEqual(r.worldTranslationMaxErrorMetres,0)
            self.assertGreater(r.originRelativeTranslationMaxErrorMetres,300)
            self.assertFalse(r.propTransformsVerified)

    def test_unmatched_duplicate_and_missing_pid_are_not_guessed(self):
        for mutation,key in (("sourceProps[0].mesh='another_mesh'",'unmatched'),
                             ("sourceProps[1]={mesh='steering',pid=92}",'ambiguous'),
                             ("sourceProps[1]={mesh='steering'}",'ambiguous'),
                             ("sourceProps[0].pid=nil",'liveUnavailable')):
            for lua,m in self.runtimes():
                lua.execute(mutation);r=self.inspect(lua,m)
                self.assertEqual(r[key],1);self.assertEqual(r.matched,0)
                self.assertFalse(r.propTransformsVerified)
                self.assertIsNone(lua.globals().requestedPid)

    def test_missing_metadata_matrix_or_bad_native_transform_explicit_not_success(self):
        for mutation,key in (('core_vehicle_manager=nil','comparisonAvailable'),
                             ('sourceProps=nil','comparisonAvailable'),
                             ('descriptor.position=nil','invalidNative'),
                             ('nativeRotation.w=0/0','invalidNative'),
                             ('descriptor.rotation={x=0,y=0,z=0,w=0}','invalidNative'),
                             ('matrix.getColumn=function()return nil end','liveUnavailable')):
            for lua,m in self.runtimes():
                lua.execute(mutation);r=self.inspect(lua,m)
                if key=='comparisonAvailable':self.assertFalse(r[key]);self.assertIsNotNone(r.reason)
                else:self.assertEqual(r[key],1)
                self.assertEqual(r.matched,0);self.assertFalse(r.propTransformsVerified)

    def test_orientation_unavailable_keeps_translation_evidence_separate(self):
        for mutation in ('quat=nil','liveRotation.w=10','matrix.toQuatF=function()error("bad quaternion")end'):
            for lua,m in self.runtimes():
                lua.execute(mutation);r=self.inspect(lua,m)
                self.assertEqual(r.matched,1);self.assertEqual(r.orientationAvailable,0)
                self.assertEqual(r.orientationUnavailable,1)
                self.assertEqual(r.originRelativeTranslationMaxErrorMetres,0)
                self.assertIsNone(r.inverseRotationMaxErrorDegrees)

    def test_accessors_zero_props_budget_and_summary_detachment(self):
        for lua,m in self.runtimes():
            lua.execute('descriptor.position=function()return nativePosition end;'
                        'descriptor.rotation=function()return nativeRotation end')
            r=self.inspect(lua,m);s=m.summary(r)
            self.assertEqual(s.matched,1);self.assertIsNone(s.details)
            s.matched=99;self.assertEqual(r.matched,1)
            lua.execute('record.propmeshes={};core_vehicle_manager=nil')
            self.assertEqual(self.inspect(lua,m).nativeProps,0)
            lua.execute('record.propmeshes={{nativeIndex=7,meshName="steering"}};'
                        'sourceProps={};for i=1,2049 do sourceProps[i]={}end;'
                        'core_vehicle_manager={getVehicleData=function()return {vdata={props=sourceProps}}end}')
            r=self.inspect(lua,m);self.assertFalse(r.comparisonAvailable)
            self.assertIn('budget',r.reason)


if __name__=='__main__':
    unittest.main()
