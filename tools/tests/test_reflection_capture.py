"""Pure mirror math and actual probe controller; does not launch BeamNG."""
from pathlib import Path
import unittest
from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT

ROOT = Path(__file__).resolve().parents[2]
MODULES = ROOT / 'lua/ge/extensions/beamrt'
MOCK = r'''
views={};failDestroy=false;creates=0;destroys=0
freshProxies=false;deferDestroy=false;pendingDeletes={}
function wrap(v)
 if not v or not freshProxies then return v end
 return setmetatable({underlying=v},{__index=v,__newindex=function(_,k,x)v[k]=x end})
end
function flushDeletes()
 for name,v in pairs(pendingDeletes)do if views[name]==v then views[name]=nil end end
 pendingDeletes={}
end
function vec3(x,y,z)return {x=x,y=y,z=z}end
function MatrixF()
 local m={columns={vec3(1,0,0),vec3(0,1,0),vec3(0,0,1),vec3(0,0,10)}}
 function m:getColumn(i)return self.columns[i+1]end
 function m:setColumn(i,v)self.columns[i+1]=v end
 return m
end
function Point2I(x,y)return {x=x,y=y}end
function RectI(x,y,w,h)return {x=x,y=y,w=w,h=h}end
Frustum={construct=function(...)return {...}end}
sourceMatrix=MatrixF()
function getCameraTransform()return sourceMatrix end
views.main={cameraMatrix=sourceMatrix,fov=90,resolution={x=1600,y=900},active=true,usePostEffects=true}
RenderViewManagerInstance={
 getView=function(self,name)return wrap(views[name])end,
 getOrCreateView=function(self,name)creates=creates+1;views[name]={};return wrap(views[name])end,
 destroyView=function(self,v)
  if failDestroy then error('Destroy refused')end
  destroys=destroys+1
  v=rawget(v,'underlying')or v
  for name,object in pairs(views)do
   if object==v then
    if deferDestroy then pendingDeletes[name]=v else views[name]=nil end
   end
  end
 end}
waterHeight=2
scenetree={findClassObjects=function(kind)assert(kind=='WaterPlane');return {'ocean'}end,
 findObject=function(name)return {getPosition=function()return vec3(0,0,waterHeight)end}end}
settings={setValue=function()error('Must not modify engine settings')end}
'''

class ReflectionCapture(unittest.TestCase):
    def runtimes(self):
        for cls in (Lua51, LuaJIT):
            lua = cls(unpack_returned_tuples=True)
            lua.execute(MOCK)
            math = lua.execute((MODULES / 'reflectionCaptureMath.lua').read_text())
            lua.globals().require = lambda name: math
            probe = lua.execute((MODULES / 'planarCapture.lua').read_text())
            lua.globals().probe = probe
            lua.globals().mathPolicy = math
            yield lua, probe

    def test_import_is_inert_and_mirror_is_right_handed_without_main_view_mutation(self):
        for lua, probe in self.runtimes():
            self.assertFalse(probe.getStatus().requested)
            self.assertEqual(lua.globals().creates, 0)
            self.assertTrue(probe.start(None, 'mirror'))
            lua.execute(r'''
            local name=probe.getStatus().viewName
            local p=views[name]
            assert(p.cameraMatrix:getColumn(3).z==-6)
            assert(p.cameraMatrix:getColumn(0).x==-1 and p.cameraMatrix:getColumn(1).y==1 and p.cameraMatrix:getColumn(2).z==-1)
            assert(p.usePostEffects==false and p.namedTexTargetColor==name)
            assert(views.main.cameraMatrix==sourceMatrix and views.main.usePostEffects==true)
            ''')

    def test_rear_pose(self):
        for lua, probe in self.runtimes():
            self.assertTrue(probe.start(None, 'rear'))
            lua.execute(r'''
            local m=views[probe.getStatus().viewName].cameraMatrix
            assert(m:getColumn(3).z==10 and m:getColumn(0).x==-1 and m:getColumn(1).y==-1 and m:getColumn(2).z==1)
            ''')

    def test_projection_and_invalid_camera_inputs(self):
        for lua, probe in self.runtimes():
            lua.execute(r'''
            local c={eye={0,0,10},right={1,0,0},forward={0,1,0},up={0,0,1},fov=90}
            local f=assert(mathPolicy.frame(c,2,'mirror'))
            local p=assert(mathPolicy.project(f,{10,20,2},1))
            assert(math.abs(p.u-.25)<1e-8 and math.abs(p.v-.7)<1e-8 and p.depth==20)
            assert(mathPolicy.project(f,{0,-20,2},1)==nil)
            assert(mathPolicy.project(f,{100,20,2},1)==nil)
            assert(mathPolicy.project(f,{0/0,20,2},1)==nil)
            c.eye={0,0,2};assert(mathPolicy.frame(c,2,'mirror')==nil)
            c.eye={0,0,10};c.right={2,0,0};assert(mathPolicy.frame(c,2,'mirror')==nil)
            c.right={1,0,0};c.fov=0/0;assert(mathPolicy.frame(c,2,'mirror')==nil)
            ''')

    def test_scheduled_frames_are_not_output_depth_or_clip_proof(self):
        for lua, probe in self.runtimes():
            self.assertTrue(probe.start(2, 'mirror'))
            for _ in range(8): probe.update()
            self.assertEqual(probe.getStatus().framesScheduled, 8)
            for key in ('outputVerified', 'depthVerified', 'planeClipVerified', 'compositeAllowed', 'gameSettingsChanged'):
                self.assertFalse(probe.getStatus()[key], key)
            name=probe.getStatus().viewName
            self.assertTrue(probe.stop())
            self.assertIsNone(lua.globals().views[name])
            self.assertTrue(lua.globals().views.main.active)

    def test_bad_inputs_and_foreign_name_fail_closed(self):
        for lua, probe in self.runtimes():
            self.assertFalse(probe.start(float('nan'), 'mirror')[0])
            self.assertFalse(probe.start(2, 'anything')[0])
            self.assertFalse(probe.start(20, 'mirror')[0])
            self.assertEqual(lua.globals().creates, 0)
            lua.execute('foreign={active=true};views.BeamRT_PlanarCaptureProbe=foreign')
            self.assertFalse(probe.start(2, 'mirror')[0])
            self.assertTrue(lua.globals().foreign.active)

    def test_fresh_native_wrappers_keep_updating_and_destroy_the_original_handle(self):
        for lua, probe in self.runtimes():
            lua.execute('freshProxies=true')
            for _ in range(3):
                self.assertTrue(probe.start(2, 'mirror'))
                for _ in range(5): probe.update()
                self.assertTrue(probe.getStatus().requested)
                self.assertEqual(probe.getStatus().framesScheduled, 5)
                name=probe.getStatus().viewName
                self.assertTrue(probe.stop())
                self.assertIsNone(lua.globals().views[name])
            self.assertEqual(lua.globals().destroys, 3)

    def test_deferred_delete_blocks_restart_without_double_destroy(self):
        for lua, probe in self.runtimes():
            lua.execute('freshProxies=true;deferDestroy=true')
            self.assertTrue(probe.start(2, 'mirror'))
            name=probe.getStatus().viewName
            self.assertFalse(probe.stop()[0])
            self.assertTrue(probe.getStatus().cleanupPending)
            self.assertFalse(lua.globals().views[name].active)
            self.assertFalse(probe.start(2, 'rear')[0])
            self.assertEqual(lua.globals().creates, 1)
            self.assertEqual(lua.globals().destroys, 1)
            lua.execute('flushDeletes()')
            self.assertTrue(probe.stop())
            self.assertFalse(probe.getStatus().cleanupPending)
            self.assertTrue(probe.start(2, 'rear'))

    def test_reserved_name_collision_is_skipped_without_adopting_foreign_view(self):
        for lua, probe in self.runtimes():
            lua.execute('foreign={active=true};views.BeamRT_PlanarCaptureProbe_1=foreign')
            self.assertTrue(probe.start(2, 'mirror'))
            self.assertEqual(probe.getStatus().viewName, 'BeamRT_PlanarCaptureProbe_2')
            self.assertTrue(probe.stop())
            self.assertTrue(lua.globals().foreign.active)
            self.assertEqual(lua.globals().destroys, 1)

    def test_failed_cleanup_is_retained_for_retry(self):
        for lua, probe in self.runtimes():
            self.assertTrue(probe.start(2, 'mirror'))
            lua.execute('failDestroy=true')
            self.assertFalse(probe.stop()[0])
            self.assertFalse(probe.start(2, 'mirror')[0])
            lua.execute('failDestroy=false')
            self.assertTrue(probe.stop())

    def test_replaced_view_is_not_touched(self):
        for lua, probe in self.runtimes():
            self.assertTrue(probe.start(2, 'mirror'))
            lua.execute('foreign={active=true};views[probe.getStatus().viewName]=foreign')
            probe.update()
            self.assertFalse(probe.getStatus().requested)
            self.assertTrue(lua.globals().foreign.active)

    def test_inspection_is_read_only_and_does_not_claim_depth_clip_support(self):
        for lua, probe in self.runtimes():
            lua.execute('SOTMExample=16')
            report=probe.inspect()
            self.assertTrue(report.mainViewAvailable)
            self.assertFalse(report.fields.namedTexTargetDepth.nonNil)
            self.assertFalse(report.depthVerified)
            self.assertFalse(report.planeClipVerified)
            self.assertEqual(lua.globals().creates,0)
            self.assertTrue(lua.globals().views.main.active)

if __name__ == '__main__': unittest.main()
