"""Actual GPUMesh provider + pair Lua lifecycle under LuaJIT. No game/GPU proof."""
from pathlib import Path
import unittest
from lupa.luajit21 import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
MODULES = ROOT / 'lua/ge/extensions/beamrt'
FIXTURE = r'''
paused=true;requests=0;freed=0;allocations=0;failSecond=false;failFree=false;events={}
journal={};journalFlushes=0;journalCloses=0;failJournal=false;failJournalStage=nil
local journalEntry
function jsonEncode(entry)
 journalEntry={};for k,v in pairs(entry)do journalEntry[k]=v end;return '{}'
end
io.open=function(path,mode)
 assert(path=='/settings/beamrtVehiclePairStages.jsonl' and mode=='a')
 if failJournal then return nil,'fake journal failure'end
 return {write=function(self)
   if failJournalStage and journalEntry.operation..'/'..journalEntry.boundary==failJournalStage then
    return nil,'fake stage write failure'
   end
   journal[#journal+1]=journalEntry;return self
  end,
  flush=function()journalFlushes=journalFlushes+1;return true end,
  close=function()journalCloses=journalCloses+1;return true end}
end
simTimeAuthority={getPause=function()return paused end}
local ffi=require('ffi')
local originalNew=ffi.new
ffi.new=function(...) allocations=allocations+1;return originalNew(...) end
cars={};meshes={}
function makeCar(id,x)
 local v={id=id,x=x,model='testcar',names={'test_body','test_glass'}}
 function v:getID()return self.id end
 function v:getClassName()return 'BeamNGVehicle' end
 function v:getJBeamFilename()return self.model end
 function v:getMeshMaterialNames()return self.names end
 function v:getPosition()return {self.x,0,0}end
 function v:getSpawnWorldOOBB()
  return {getCenter=function()return {self.x,0,0}end,getHalfExtents=function()return {3,3,3}end,
   getAxis=function(_,i)local a={0,0,0};a[i+1]=1;return a end}
 end
 local mesh={verticesCount=3,indicesCount=3,normalsCount=0,tangentsCount=0,
  uv1Count=0,uv2Count=0,vertColorsCount=0,flexmeshesCount=1,propmeshesCount=0,
  dataIsReady=false,positions={-1,0,1,1,0,1,0,1,1},ids={0,1,2},primitiveStart=0,primitiveCount=3}
 function mesh:verticesGet(dst)for i,v in ipairs(self.positions)do dst[i-1]=v end;return true end
 function mesh:indicesGet(dst)for i,v in ipairs(self.ids)do dst[i-1]=v end;return true end
 local desc={meshName='body',primitivesCount=1}
 function desc:primitivesGet(dst)
  dst[0].startIndex=mesh.primitiveStart;dst[0].indexCount=mesh.primitiveCount
  dst[0].materialId=mesh.materialId or 0;return true
 end
 function mesh:flexmeshes(i)assert(i==0);return desc end
 function mesh:propmeshes(i)assert(i==0);return self.prop end
 function mesh:free()events[#events+1]='free:'..id;freed=freed+1;if failFree then error('unknown free outcome')end end
 cars[id]=v;meshes[id]=mesh;return v,mesh
end
makeCar(41,100);makeCar(42,110)
be={getObjectByID=function(_,id)return cars[id]end,getObjectCount=function()return 2 end,
 getObject=function(_,i)return cars[41+i]end,getPlayerVehicleID=function()return 41 end}
function getObjectByID(id)return cars[id]end
GPUMesh={bng_getGPUMesh=function(id)
 events[#events+1]='request:'..id;requests=requests+1;if failSecond and id==42 then return nil end;return meshes[id]
end}
'''


class VehiclePairProbe(unittest.TestCase):
    def production_source(self):
        # Every GPUMesh getter and journal in this fixture is Lua-owned. Use the
        # shipped source unchanged; offline passing is not native safety proof.
        source=(MODULES/'vehiclePairProbe.lua').read_text()
        self.assertIn('local ACQUISITION_BLOCKED = false',source)
        return source

    def runtime(self):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(FIXTURE)
        for stem in ('worldMeshCasters','worldBoxCasters','providers/lightProvider',
                     'providers/materialProvider','providers/tsStaticProvider'):
            lua.globals().package.loaded['ge/extensions/beamrt/'+stem]=lua.table()
        factory=lua.eval('function(source) return function() return assert(loadstring(source))() end end')
        for stem in ('vehicleAlignmentPreview','vehicleRayProbe','vehicleGeometryBVH','vehicleRayImage','vehicleReflectionMask',
                     'vehicleCameraSnapshot','vehicleOffscreenGeometry','vehicleCameraReflectionMask','vehicleMaterialSnapshot','vehicleGpuProbe','vehicleGpuImage'):
            lua.globals().package.preload['ge/extensions/beamrt/'+stem]=factory((MODULES/(stem+'.lua')).read_text())
        for stem in ('providers/vehicleProvider', 'glassGeometry', 'vehiclePropPlacement',
                     'vehicleAlignmentPreview','geometryTriangleIntersection','sceneVisibility','vehicleRayProbe'):
            module = lua.execute((MODULES / (stem + '.lua')).read_text())
            lua.globals().package.loaded['ge/extensions/beamrt/' + stem] = module
        source=self.production_source()
        probe = lua.execute(source)
        lua.globals().probe = probe
        return lua, probe

    def ready(self, lua):
        lua.execute('meshes[41].dataIsReady=true;meshes[42].dataIsReady=true')

    def test_explicit_pair_async_readback_once_no_tracer_claim(self):
        lua, m = self.runtime()
        self.assertEqual(len(m.listVehicles()), 2)
        self.assertEqual(lua.globals().requests, 0)
        self.assertTrue(m.start(41, 42)[0])
        m.onUpdate(.1)
        self.assertEqual(m.getStatus().phase, 'pending')
        self.assertEqual(lua.globals().allocations, 0)
        # Callable readiness is accepted too, without acquiring again.
        lua.execute('meshes[41].dataIsReady=function()return 1 end;meshes[42].dataIsReady=true')
        m.onUpdate(.1)
        report = m.getStatus()
        self.assertTrue(report.inspected)
        self.assertEqual(lua.globals().requests, 2)
        self.assertEqual(lua.globals().freed, 2)
        self.assertEqual(report.vehicles[1].id, 41)
        self.assertEqual(report.vehicles[2].id, 42)
        self.assertEqual(report.vehicles[1].flexTriangles, 1)
        self.assertEqual(report.vehicles[1].rawFlexBounds.min[1], -1)
        self.assertTrue(report.vehicles[1].originRelativeBoundsCandidate)
        self.assertFalse(report.vehicles[1].worldBoundsCandidate)
        for key in ('feedsRayTracer', 'reflectionsEnabled', 'offscreenTestPassed',
                    'geometryFreshnessVerified', 'materialShadingVerified'):
            self.assertFalse(report[key])
        self.assertFalse(report.vehicles[1].coordinateFrameVerified)
        self.assertIsNone(lua.eval("require('ge/extensions/beamrt/providers/vehicleProvider').get(41)"))
        report.vehicles[1].pose.position[1] = 9999
        self.assertEqual(m.getStatus().vehicles[1].pose.position[1], 100)
        self.assertFalse(m.start(41, 42)[0])
        m.stop();m.stop()
        self.assertEqual(lua.globals().freed, 2)

    def test_bad_selection_unpaused_walking_or_missing_target_no_native_requests(self):
        for mutation, a, b in (
            ('paused=false',41,42), ('',41,41), ('',41,99), ('',41.5,42), ('', '41',42),
            ("cars[42].model='unicycle'",41,42),
            ("cars[42].getClassName=function()return 'TSStatic'end",41,42),
        ):
            with self.subTest(mutation=mutation,a=a,b=b):
                lua, m = self.runtime();lua.execute(mutation)
                self.assertFalse(m.start(a,b)[0])
                self.assertEqual(lua.globals().requests, 0)

    def test_partial_acquisition_failure_releases_first_native_request(self):
        lua,m=self.runtime();lua.execute('failSecond=true')
        self.assertTrue(m.start(41,42)[0]);self.ready(lua);m.update(.1)
        self.assertEqual(m.getStatus().phase,'stopped');self.assertEqual(lua.globals().freed,1)
        m.onExtensionUnloaded();self.assertEqual(lua.globals().freed,1)

    def test_timeout_and_pending_cancel_release_only_outstanding_handle(self):
        for action in ('timeout','unload','mission','reset','destroy'):
            with self.subTest(action=action):
                lua,m=self.runtime();m.start(41,42)
                if action=='timeout':m.update(10)
                elif action=='unload':m.onExtensionUnloaded()
                elif action=='mission':m.onClientEndMission()
                elif action=='reset':m.onVehicleResetted(42)
                else:m.onVehicleDestroyed(42)
                self.assertEqual(m.getStatus().phase,'stopped')
                self.assertEqual(lua.globals().freed,1)
                self.assertEqual(lua.globals().requests,1)

    def test_pose_identity_pause_and_material_names_invalidate_snapshot(self):
        for mutation in ('cars[42].x=111','cars[42]=nil','paused=false',
                         "cars[42].names[1]='changed'",'makeCar(42,110)'):
            with self.subTest(mutation=mutation):
                lua,m=self.runtime();m.start(41,42);self.ready(lua);m.update(.1)
                lua.execute(mutation)
                # A status query alone must refuse stale inspected reports.
                status=m.getStatus();self.assertFalse(status.inspected)
                self.assertEqual(len(status.vehicles),0)
                self.assertEqual(lua.globals().freed,2)

    def test_count_budgets_reject_before_ffi_allocation(self):
        for mutation in ('meshes[41].verticesCount=500001', 'meshes[41].indicesCount=0/0',
                         'meshes[41].flexmeshesCount=257',
                         'meshes[41].verticesCount=500000;meshes[41].indicesCount=1500000;'
                         'meshes[41].propmeshesCount=2;meshes[41].primitivesCount=1;'
                         'meshes[41].propmeshes=function(self,i)return self end'):
            with self.subTest(mutation=mutation):
                lua,m=self.runtime();m.start(41,42);self.ready(lua);lua.execute(mutation);m.update(.1)
                self.assertFalse(m.getStatus().inspected)
                self.assertEqual(lua.globals().allocations,0)
                self.assertEqual(lua.globals().freed,1)

    def test_bad_vertex_index_range_or_core_buffer_fails_closed(self):
        for mutation in ('meshes[41].positions[1]=0/0','meshes[41].ids[3]=999',
                         'meshes[41].primitiveStart=1','meshes[41].primitiveCount=6',
                         'meshes[41].verticesGet=function()return false end'):
            with self.subTest(mutation=mutation):
                lua,m=self.runtime();m.start(41,42);self.ready(lua);lua.execute(mutation);m.update(.1)
                status=m.getStatus();self.assertFalse(status.inspected)
                self.assertEqual(lua.globals().freed,1)
                self.assertIsNone(lua.eval("require('ge/extensions/beamrt/providers/vehicleProvider').get(41)"))

    def test_props_and_unknown_materials_are_not_certified_as_complete_cars(self):
        lua,m=self.runtime()
        lua.execute('''
        local p=meshes[41]
        p.propmeshesCount=1;p.prop=p;p.primitivesCount=1;p.materialId=99
        function p:primitivesGet(dst)dst[0].startIndex=0;dst[0].indexCount=3;dst[0].materialId=99;return true end
        ''')
        m.start(41,42);self.ready(lua);m.update(.1)
        status=m.getStatus();self.assertTrue(status.inspected)
        report=status.vehicles[1]
        self.assertEqual(report.propMeshes,1);self.assertEqual(report.propTriangles,1)
        self.assertEqual(report.unresolvedPrimitives,2)
        self.assertFalse(report.propTransformsVerified)
        self.assertFalse(report.completeVehicleGeometryVerified)

    def test_near_origin_ambiguity_is_reported_not_guessed(self):
        lua,m=self.runtime();lua.execute('cars[41].x=0')
        m.start(41,42);self.ready(lua);m.update(.1)
        report=m.getStatus().vehicles[1]
        self.assertTrue(report.worldBoundsCandidate)
        self.assertTrue(report.originRelativeBoundsCandidate)
        self.assertFalse(report.coordinateFrameVerified)

    def test_exporter_inverse_axes_candidate_uses_world_relative_not_double_rotation(self):
        lua,m=self.runtime()
        lua.execute('''
        local q=math.sqrt(.5)
        for id,v in pairs(cars)do
          function v:getPosition()return {self.x,20,30}end
          function v:getSpawnWorldOOBB()
            return {getCenter=function()return {self.x,20,31}end,
              getHalfExtents=function()return {.9,2,.5}end,
              getAxis=function(_,i)return ({ {q,q,0},{-q,q,0},{0,0,1} })[i+1]end}
          end
          -- Independently form ENGINE world-relative vertices from the OOBB
          -- basis, then encode them in the exporter's x,z,-y convention.
          local source={{0,-1.9,.6},{0,1.9,1.4},{.7,0,1}}
          local p={}
          for _,v in ipairs(source)do
            local dx=q*v[1]-q*v[2];local dy=q*v[1]+q*v[2]
            p[#p+1]=dx;p[#p+1]=v[3];p[#p+1]=-dy
          end
          meshes[id].positions=p
        end
        ''')
        m.start(41,42);self.ready(lua);m.update(.1)
        status=m.getStatus();self.assertTrue(status.inspected)
        for row in status.vehicles.values():
            self.assertFalse(row.worldBoundsCandidate)
            self.assertFalse(row.originRelativeBoundsCandidate)
            self.assertTrue(row.exporterAxesOriginRelativeBoundsCandidate)
            self.assertAlmostEqual(row.exporterAxesMaxOutsideMetres,0)
            self.assertFalse(row.coordinateFrameVerified)
            self.assertFalse(row.completeVehicleGeometryVerified)

    def test_exporter_axes_failure_reports_outside_distance_without_changing_claims(self):
        lua,m=self.runtime();lua.execute('meshes[41].positions[2]=100')
        m.start(41,42);self.ready(lua);m.update(.1)
        row=m.getStatus().vehicles[1]
        self.assertFalse(row.exporterAxesOriginRelativeBoundsCandidate)
        self.assertAlmostEqual(row.exporterAxesMaxOutsideMetres,97)
        self.assertFalse(row.coordinateFrameVerified)

    def test_compact_status_retains_guards_and_detaches_from_evidence(self):
        lua,m=self.runtime();m.start(41,42);self.ready(lua);m.update(.1)
        status=m.getSummary();self.assertEqual(status.diagnosticRevision,16)
        self.assertEqual(status.phase,'inspected');self.assertEqual(len(status.vehicles),2)
        self.assertIsNone(status.vehicles[1].materials)
        self.assertIsNone(status.vehicles[1].pose)
        self.assertFalse(status.vehicles[1].coordinateFrameVerified)
        self.assertFalse(status.offscreenTestPassed);self.assertFalse(status.feedsRayTracer)
        status.vehicles[1].id=99;self.assertEqual(m.getSummary().vehicles[1].id,41)
        lua.execute('paused=false')
        self.assertEqual(m.getSummary().phase,'stopped')
        self.assertEqual(len(m.getSummary().vehicles),0)

    def test_other_provider_cache_not_overwritten_at_start_or_during_wait(self):
        for during_wait in (False,True):
            lua,m=self.runtime()
            lua.execute("provider=require('ge/extensions/beamrt/providers/vehicleProvider')")
            if during_wait:m.start(41,42)
            lua.execute('meshes[41].dataIsReady=true;external=provider.capture(41,meshes[41])')
            if during_wait:self.ready(lua);m.update(.1)
            else:self.assertFalse(m.start(41,42)[0])
            self.assertTrue(lua.eval('provider.get(41)==external'))
            self.assertFalse(m.getStatus().inspected)

    def test_uncertain_native_free_never_retried_or_called_success(self):
        lua,m=self.runtime();m.start(41,42);self.ready(lua);lua.execute('failFree=true');m.update(.1)
        status=m.getStatus();self.assertTrue(status.cleanupUnverified);self.assertFalse(status.inspected)
        self.assertEqual(lua.globals().freed,1)
        self.assertEqual(lua.globals().requests,1)
        m.stop();self.assertEqual(lua.globals().freed,1)
        self.assertFalse(m.start(41,42)[0])

    def test_only_one_readback_pending_and_a_freed_before_requesting_b(self):
        lua,m=self.runtime();self.assertTrue(m.start(41,42)[0])
        self.assertEqual(lua.globals().requests,1)
        m.update(.1);self.assertEqual(lua.globals().requests,1)
        lua.execute('meshes[41].dataIsReady=true');m.update(.1)
        self.assertEqual(m.getStatus().phase,'pending')
        self.assertEqual(list(lua.globals().events.values()),['request:41','free:41','request:42'])
        self.assertEqual(lua.globals().freed,1)
        lua.execute('meshes[42].dataIsReady=true');m.update(.1)
        self.assertTrue(m.getStatus().inspected)
        self.assertEqual(list(lua.globals().events.values()),['request:41','free:41','request:42','free:42'])

    def test_preview_opt_in_drawing_expiry_and_stale_pair_never_draws(self):
        lua,m=self.runtime()
        lua.execute('''
        drawn=0
        function vec3(x,y,z)return {x=x,y=y,z=z}end
        function ColorF(r,g,b,a)return {}end
        debugDrawer={drawLine=function()drawn=drawn+1 end}
        ''')
        m.start(41,42);self.ready(lua);m.update(.1)
        self.assertTrue(m.getSummary().alignmentPreview.ready)
        self.assertFalse(m.getSummary().alignmentPreview.enabled)
        m.onPreRender();self.assertEqual(lua.globals().drawn,0)
        for duration in (0,-1,121,float('nan')):
            self.assertFalse(m.showAlignment(duration)[0])
        self.assertTrue(m.showAlignment(1)[0]);m.onPreRender()
        self.assertEqual(lua.globals().drawn,6)
        m.onUpdate(1);m.onPreRender();self.assertEqual(lua.globals().drawn,6)
        self.assertFalse(m.getSummary().alignmentPreview.enabled)
        self.assertTrue(m.showAlignment(30)[0]);m.hideAlignment();m.onPreRender()
        self.assertEqual(lua.globals().drawn,6)
        self.assertTrue(m.showAlignment(30)[0]);lua.execute('paused=false');m.onPreRender()
        self.assertEqual(lua.globals().drawn,6)
        self.assertEqual(m.getStatus().phase,'stopped')
        self.assertEqual(lua.globals().freed,2)
        self.assertFalse(m.getStatus().offscreenTestPassed)

    def test_full_hit_job_lifecycle_detachment_cancellation_and_no_extra_readbacks(self):
        lua,m=self.runtime()
        lua.execute('for _,mesh in pairs(meshes)do mesh.positions={-3,-1,1,-3,1,1,-3,0,-1}end')
        self.assertTrue(m.startHitTest(41,42)[0]);self.ready(lua);m.update(.01)
        self.assertEqual(m.getHitTestStatus().phase,'running')
        self.assertEqual(lua.globals().freed,2)
        for _ in range(10):m.update(.01)
        status=m.getHitTestStatus();self.assertEqual(status.phase,'complete')
        self.assertTrue(status.geometricControlsPassed)
        status.results[1].hit.vehicleId=999
        self.assertEqual(m.getHitTestStatus().results[1].hit.vehicleId,42)
        self.assertEqual(lua.globals().requests,2)
        self.assertFalse(m.getStatus().offscreenTestPassed)
        lua.execute('paused=false');self.assertEqual(m.getHitTestStatus().phase,'cancelled')
        self.assertEqual(m.getStatus().phase,'stopped')

    def test_extension_reload_refreshes_older_stateless_helper_apis(self):
        lua,m=self.runtime();m.onExtensionUnloaded()
        lua.execute("package.loaded['ge/extensions/beamrt/vehicleAlignmentPreview']={};"
                    "package.loaded['ge/extensions/beamrt/vehicleRayProbe']={}")
        refreshed=lua.execute(self.production_source())
        self.assertTrue(refreshed.start(41,42)[0]);self.ready(lua);refreshed.update(.01)
        self.assertTrue(refreshed.getSummary().alignmentPreview.ready)
        self.assertEqual(refreshed.getSummary().diagnosticRevision,16)

    def test_opt_in_production_controller_never_requests_on_load_and_rejects_stale_provider(self):
        lua,m=self.runtime()
        self.assertEqual(lua.globals().requests,0);self.assertFalse(m.getSummary().acquisitionBlocked)
        self.assertEqual(m.getSummary().diagnosticRevision,16)
        lua.execute("require('ge/extensions/beamrt/providers/vehicleProvider').diagnosticStageVersion=nil")
        for call in (lambda:m.start(41,42),lambda:m.startHitTest(41,42)):
            ok,why=call();self.assertFalse(ok);self.assertIn('Stale provider',why)
        self.assertEqual(lua.globals().requests,0);self.assertEqual(lua.globals().freed,0)

    def test_automatic_hit_pair_uses_controlled_vehicle_and_requires_exactly_two_cars(self):
        lua,m=self.runtime();self.assertTrue(m.startHitTest()[0])
        self.assertEqual(lua.globals().requests,1);self.assertEqual(lua.globals().events[1],'request:41')
        for mutation in ('be.getObjectCount=function()return 1 end',
                         "cars[42].model='unicycle'",'be.getPlayerVehicleID=function()return 99 end'):
            lua,m=self.runtime();lua.execute(mutation);self.assertFalse(m.startHitTest()[0])
            self.assertEqual(lua.globals().requests,0)
        lua,m=self.runtime();lua.execute('be.getPlayerVehicleID=function()return 42 end')
        self.assertTrue(m.startHitTest()[0]);self.assertEqual(lua.globals().events[1],'request:42')

    def test_pair_journal_records_request_copy_free_and_complete_without_handle_data(self):
        lua,m=self.runtime()
        lua.execute('for _,mesh in pairs(meshes)do mesh.positions={-3,-1,1,-3,1,1,-3,0,-1}end')
        self.assertTrue(m.startHitTest()[0]);self.ready(lua);m.update(.01)
        for _ in range(10):m.update(.01)
        self.assertEqual(m.getHitTestStatus().phase,'complete')
        entries=list(lua.globals().journal.values())
        self.assertEqual(entries[-1].operation,'cpuControlsComplete')
        self.assertEqual([entry.sequence for entry in entries],list(range(1,len(entries)+1)))
        for id in (41,42):
            selected=[entry for entry in entries if entry.vehicleId==id]
            for op in ('request','dataIsReady','verticesGet','indicesGet','primitivesGet','free'):
                self.assertTrue(any(e.operation==op and e.boundary=='before' for e in selected),op)
                self.assertTrue(any(e.operation==op and e.boundary=='after' for e in selected),op)
            self.assertTrue(all(type(v) in (str,int,float) for e in selected for v in e.values()))
        self.assertLess(next(e.sequence for e in entries if e.vehicleId==41 and e.operation=='free' and e.boundary=='after'),
                        next(e.sequence for e in entries if e.vehicleId==42 and e.operation=='request' and e.boundary=='before'))
        self.assertEqual(lua.globals().journalFlushes,len(entries));self.assertEqual(lua.globals().journalCloses,len(entries))

    def test_pair_journal_failures_never_skip_owned_cleanup_or_request_second_car(self):
        for operation in ('request/before','request/after','verticesGet/before','captureGeometry/after',
                          'prepareTransforms/after','free/before','free/after'):
            lua,m=self.runtime();lua.execute("failJournalStage='"+operation+"'")
            ok,_=m.start(41,42)
            if ok:self.ready(lua);m.update(.1)
            status=m.getSummary();self.assertEqual(status.phase,'stopped',operation)
            self.assertTrue(status.journalFailed,operation)
            self.assertEqual(lua.globals().requests,0 if operation=='request/before' else 1)
            self.assertEqual(lua.globals().freed,lua.globals().requests)
            self.assertFalse(m.startHitTest(41,42)[0]);m.stop();m.onExtensionUnloaded()
            self.assertEqual(lua.globals().freed,lua.globals().requests)
            self.assertIsNone(lua.eval("require('ge/extensions/beamrt/providers/vehicleProvider').get(41)"))

    def test_geometry_preflight_and_provider_never_touch_excluded_optional_streams(self):
        lua,m=self.runtime()
        lua.execute('''
        optionalTouched=0
        for _,mesh in pairs(meshes)do
          local forbidden={}
          for _,stem in ipairs({'normals','tangents','uv1','uv2','vertColors'})do
            for _,suffix in ipairs({'Count','Get'})do local k=stem..suffix;mesh[k]=nil;forbidden[k]=true end
          end
          setmetatable(mesh,{__index=function(_,key)
            if forbidden[key]then optionalTouched=optionalTouched+1;error('Excluded stream accessed')end
          end})
        end
        ''')
        self.assertTrue(m.start(41,42)[0]);self.ready(lua);m.update(.1)
        self.assertTrue(m.getStatus().inspected)
        self.assertEqual(lua.globals().optionalTouched,0)
        self.assertEqual(lua.globals().requests,2);self.assertEqual(lua.globals().freed,2)


if __name__=='__main__':
    unittest.main()
