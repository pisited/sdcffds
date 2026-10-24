"""Single-car opt-in lifecycle; real LuaJIT FFI, fake native getters and journal."""
import unittest
from lupa.luajit21 import LuaRuntime
from test_vehicle_pair_probe import FIXTURE,MODULES
from test_vehicle_provider_profiles import EXTRA

JOURNAL=r'''
journal={};writes=0;flushes=0;closes=0;failOpen=false;failWrite=false;failFlush=false;failStage=nil
be.getPlayerVehicleID=function()return 41 end
function jsonEncode(entry)
 local detached={};for k,v in pairs(entry)do detached[k]=v end
 journal[#journal+1]=detached
 return entry.scope..'/'..entry.operation..'/'..entry.boundary
end
io.open=function(path,mode)
 assert(path=='/settings/beamrtVehicleReadbackStages.jsonl' and mode=='a')
 if failOpen then return nil,'fake journal unavailable'end
 return {
  write=function(self,content)
   if failWrite or (failStage and content==failStage..'\n')then return nil,'fake write failed'end
   writes=writes+1;events[#events+1]='write:'..content:gsub('\n','');return self
  end,
  flush=function()flushes=flushes+1;if failFlush then return nil,'fake flush failed'end;return true end,
  close=function()closes=closes+1;return true end}
end
'''


class VehicleReadbackProbe(unittest.TestCase):
    def runtime(self):
        lua=LuaRuntime(unpack_returned_tuples=True);lua.execute(FIXTURE);lua.execute(EXTRA);lua.execute(JOURNAL)
        for stem in ('providers/vehicleProvider','glassGeometry'):
            module=lua.execute((MODULES/(stem+'.lua')).read_text())
            lua.globals().package.loaded['ge/extensions/beamrt/'+stem]=module
        probe=lua.execute((MODULES/'vehicleReadbackProbe.lua').read_text())
        lua.globals().probe=probe
        return lua,probe

    def run_ready(self,lua,m):
        self.assertTrue(m.start()[0]);lua.execute('meshes[41].dataIsReady=true');m.update(.1)
        return m.getStatus()

    def test_no_autostart_and_one_controlled_car_geometry_copy_with_single_free(self):
        lua,m=self.runtime();self.assertEqual(lua.globals().requests,0)
        lua.execute('addPaddles();forbidOptional(meshes[41],false);forbidOptional(meshes[41].prop,false)')
        self.assertTrue(m.start()[0]);self.assertFalse(m.start()[0]);m.update(.1)
        self.assertEqual(m.getStatus().phase,'pending');self.assertEqual(lua.globals().allocations,0)
        lua.execute('meshes[41].dataIsReady=function()return 1 end');m.update(.1)
        status=m.getStatus();self.assertEqual(status.phase,'complete',status.reason)
        self.assertEqual(status.summary.id,41);self.assertEqual(status.summary.flexTriangles,1)
        self.assertEqual(status.summary.propTriangles,562);self.assertEqual(status.summary.propMeshes,1)
        self.assertEqual(status.summary.verticesChecked,482);self.assertEqual(status.summary.indicesChecked,1689)
        self.assertEqual(lua.globals().requests,1);self.assertEqual(lua.globals().freed,1)
        self.assertEqual(lua.globals().optionalLookups,0);self.assertEqual(lua.globals().colorCalls,0)
        self.assertIsNone(lua.eval("require('ge/extensions/beamrt/providers/vehicleProvider').get(41)"))
        self.assertFalse(status.feedsRayTracer);self.assertFalse(status.reflectionsEnabled)
        self.assertFalse(status.offscreenTestPassed);self.assertFalse(status.summary.coordinateFrameVerified)
        m.update(20);m.onExtensionUnloaded();self.assertEqual(m.getStatus().phase,'complete')
        status.summary.id=9;status.lastStage.operation='changed'
        self.assertEqual(m.getStatus().summary.id,41);self.assertEqual(m.getStatus().lastStage.operation,'complete')
        self.assertEqual(lua.globals().freed,1)

    def test_append_flush_close_boundaries_before_request_and_free(self):
        lua,m=self.runtime();self.run_ready(lua,m)
        events=list(lua.globals().events.values())
        for operation,event in (('request','request:41'),('free','free:41')):
            self.assertLess(events.index('write:owner/'+operation+'/before'),events.index(event))
            self.assertGreater(events.index('write:owner/'+operation+'/after'),events.index(event))
        self.assertEqual(lua.globals().writes,lua.globals().flushes)
        self.assertEqual(lua.globals().writes,lua.globals().closes)
        stages=list(lua.globals().journal.values())
        self.assertEqual([s.sequence for s in stages],list(range(1,len(stages)+1)))
        first_run=stages[0].run
        self.run_ready(lua,m)
        self.assertNotEqual(m.getStatus().run,first_run)
        self.assertGreater(len(lua.globals().journal),len(stages))
        self.assertEqual(lua.globals().requests,2);self.assertEqual(lua.globals().freed,2)

    def test_bad_preflight_never_requests_or_frees_native_mesh(self):
        for mutation,target in (('paused=false',None),('',99),('',41.5),('', '41'),
                                ("cars[41].model='unicycle'",None),
                                ("cars[41].getClassName=function()return 'TSStatic'end",None),
                                ("require('ge/extensions/beamrt/providers/vehicleProvider').diagnosticStageVersion=nil",None)):
            with self.subTest(mutation=mutation,target=target):
                lua,m=self.runtime();lua.execute(mutation);self.assertFalse(m.start(target)[0])
                self.assertEqual(lua.globals().requests,0);self.assertEqual(lua.globals().freed,0)

    def test_request_none_or_lua_exception_does_not_invent_owned_handle(self):
        for body in ('return nil',"error('native binding failure')"):
            lua,m=self.runtime();lua.execute('GPUMesh.bng_getGPUMesh=function()requests=requests+1;'+body+' end')
            self.assertFalse(m.start()[0]);self.assertEqual(lua.globals().requests,1)
            self.assertEqual(lua.globals().freed,0);self.assertEqual(m.getStatus().phase,'stopped')

    def test_pending_cancel_timeout_reset_and_pose_identity_pause_guards(self):
        for mutation in ('cars[41].x=101','cars[41]=nil','paused=false',
                         "cars[41].names[1]='different'",'makeCar(41,100)'):
            lua,m=self.runtime();m.start();lua.execute(mutation);m.update(.1)
            self.assertEqual(m.getStatus().phase,'stopped');self.assertEqual(lua.globals().freed,1)
        for action in ('timeout','stop','unload','startMission','endMission','reset','destroy'):
            lua,m=self.runtime();m.start()
            if action=='timeout':m.update(10)
            elif action=='stop':m.stop()
            elif action=='unload':m.onExtensionUnloaded()
            elif action=='startMission':m.onClientStartMission()
            elif action=='endMission':m.onClientEndMission()
            elif action=='reset':m.onVehicleResetted(41)
            else:m.onVehicleDestroyed(41)
            self.assertEqual(m.getStatus().phase,'stopped');self.assertEqual(lua.globals().freed,1)
            m.stop();m.onExtensionUnloaded();self.assertEqual(lua.globals().freed,1)

    def test_journal_failure_prevents_request_or_copy_but_never_skips_owned_free(self):
        for mutation in ('failOpen=true','failWrite=true','failFlush=true'):
            lua,m=self.runtime();lua.execute(mutation);self.assertFalse(m.start()[0])
            self.assertEqual(lua.globals().requests,0);self.assertTrue(m.getStatus().journalFailed)
            self.assertFalse(m.start()[0])
            lua,m=self.runtime();m.start();lua.execute(mutation);m.update(.1)
            self.assertEqual(m.getStatus().phase,'stopped');self.assertTrue(m.getStatus().journalFailed)
            self.assertEqual(lua.globals().freed,1);self.assertEqual(lua.globals().allocations,0)
            m.stop();self.assertEqual(lua.globals().freed,1)

    def test_bad_getter_or_cpu_contents_release_once_and_do_not_publish_success(self):
        for mutation in ('meshes[41].verticesGet=function()return false end',
                         'meshes[41].indicesGet=function()return nil end',
                         'meshes[41].positions[1]=0/0','meshes[41].ids[3]=999',
                         'meshes[41].verticesCount=500001'):
            lua,m=self.runtime();lua.execute(mutation);status=self.run_ready(lua,m)
            self.assertEqual(status.phase,'stopped');self.assertIsNone(status.summary)
            self.assertEqual(lua.globals().freed,1)
            self.assertIsNone(lua.eval("require('ge/extensions/beamrt/providers/vehicleProvider').get(41)"))

    def test_journal_failure_after_request_or_during_copy_releases_owned_resources(self):
        for stage in ('owner/request/after','root/verticesGet/before','owner/captureGeometry/after',
                      'owner/free/before','owner/free/after','owner/complete/after'):
            with self.subTest(stage=stage):
                lua,m=self.runtime();lua.execute("failStage='"+stage+"'")
                ok,_=m.start()
                if ok:lua.execute('meshes[41].dataIsReady=true');m.update(.1)
                status=m.getStatus();self.assertEqual(status.phase,'stopped');self.assertTrue(status.journalFailed)
                self.assertIsNone(status.summary);self.assertEqual(lua.globals().freed,1)
                self.assertIsNone(lua.eval("require('ge/extensions/beamrt/providers/vehicleProvider').get(41)"))
                self.assertFalse(m.start()[0]);m.onExtensionUnloaded()
                self.assertEqual(lua.globals().freed,1)

    def test_free_error_blocks_retries_and_never_double_frees(self):
        for mutation in ('failFree=true','meshes[41].free=function()freed=freed+1;return false end'):
            lua,m=self.runtime();lua.execute(mutation);status=self.run_ready(lua,m)
            self.assertEqual(status.phase,'stopped');self.assertTrue(status.cleanupUnverified)
            self.assertFalse(m.start()[0]);m.stop();m.onExtensionUnloaded()
            self.assertEqual(lua.globals().freed,1);self.assertEqual(lua.globals().requests,1)

    def test_stage_history_identifies_lua_getter_failure_without_entering_color_getter(self):
        lua,m=self.runtime();lua.execute('''
        addPaddles()
        meshes[41].prop.indicesGet=function()error('simulated index getter failure')end
        ''')
        status=self.run_ready(lua,m);self.assertEqual(status.phase,'stopped')
        entries=list(lua.globals().journal.values())
        self.assertTrue(any(s.scope=='propmeshes[0]:ardente_paddles' and s.operation=='indicesGet' and s.boundary=='before' for s in entries))
        self.assertFalse(any(s.scope=='propmeshes[0]:ardente_paddles' and s.operation=='primitivesGet' for s in entries))
        self.assertEqual(lua.globals().colorCalls,0);self.assertEqual(lua.globals().freed,1)


if __name__=='__main__':unittest.main()
