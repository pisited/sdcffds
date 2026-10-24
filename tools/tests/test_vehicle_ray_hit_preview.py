"""Detached ray markers + controller guards; no game drawing/native readback."""
import unittest
from lupa.luajit21 import LuaRuntime
import test_vehicle_pair_probe as pair_test
MODULES=pair_test.MODULES

FIXTURE=r'''
paused=true;lines={};spheres={};statusCalls=0;compactCalls=0
simTimeAuthority={getPause=function()return paused end}
function vec3(x,y,z)return {x=x,y=y,z=z}end
function ColorF(r,g,b,a)return {r=r,g=g,b=b,a=a}end
debugDrawer={drawLine=function(_,a,b,color,xray)lines[#lines+1]={a=a,b=b,color=color,xray=xray}end,
 drawSphere=function(_,p,r,color,xray)spheres[#spheres+1]={point=p,radius=r,color=color,xray=xray}end}
local function ray(name,a,b,hit,expected)
 return {name=name,origin=a,target=b,geometricHit=hit,expectedVehicleId=expected,controlPassed=true,
  hit=hit and {point={a[1]+2,a[2],a[3]},distance=2,vehicleId=expected,meshName='door',materialName='paint'}or nil}
end
full={phase='inspected',run='completed-pair-1',cleanupUnverified=false,journalFailed=false,
 vehicleHitTest={phase='complete',results={
  ray('A to B',{0,0,1},{4,0,1},true,42),ray('B to A',{10,0,1},{14,0,1},true,41),
  ray('above both cars',{0,0,15},{0,0,25},false),ray('A to B with B excluded',{0,0,1},{4,0,1},false)}}}
pair={getStatus=function()statusCalls=statusCalls+1;return full end}
extensions={beamrt_vehiclePairProbe=pair}
GPUMesh={bng_getGPUMesh=function()error('Overlay must NEVER acquire geometry')end}
pair.startHitTest=function()error('Overlay must NEVER start CPU jobs')end
'''


class RayHitPreview(unittest.TestCase):
    def runtime(self):
        lua=LuaRuntime(unpack_returned_tuples=True);lua.execute(FIXTURE)
        module=lua.execute((MODULES/'vehicleRayHitPreview.lua').read_text())
        lua.globals().overlay=module
        return lua,module

    def test_no_auto_draw_or_readback_and_default_two_hits_at_exact_cpu_points(self):
        lua,m=self.runtime();m.onPreRender();self.assertEqual(len(lua.globals().lines),0)
        self.assertTrue(m.show()[0]);self.assertEqual(m.getStatus().secondsRemaining,90)
        m.onPreRender();self.assertEqual(len(lua.globals().lines),10);self.assertEqual(len(lua.globals().spheres),4)
        lines=lua.globals().lines;spheres=lua.globals().spheres
        self.assertEqual(lines[1].b.x,4);self.assertEqual(lines[2].b.x,2)
        self.assertEqual(lines[2].color.g,.9);self.assertEqual(lines[7].color.r,1)
        self.assertEqual(spheres[2].point.x,2);self.assertEqual(spheres[4].point.x,12)
        self.assertEqual(spheres[2].radius,.08)
        self.assertTrue(all(line.xray for line in lines.values()))
        self.assertTrue(all(sphere.xray for sphere in spheres.values()))
        for key in ('reflectionsEnabled','startsCPUJobs','alignmentVerified','opaqueVisibilityVerified'):
            self.assertFalse(m.getStatus()[key])
        self.assertTrue(m.getStatus().throughBodyDebug);self.assertEqual(m.getStatus().meshReadbacksRequested,0)

    def test_all_controls_or_one_selection_without_changing_endpoints(self):
        for selection,expected_lines,expected_spheres in (('all',14,6),(1,5,2),(2,5,2),(3,2,1),(4,2,1)):
            lua,m=self.runtime();self.assertTrue(m.show(30,selection)[0]);m.onPreRender()
            self.assertEqual(len(lua.globals().lines),expected_lines)
            self.assertEqual(len(lua.globals().spheres),expected_spheres)
            if selection==3:self.assertEqual(lua.globals().lines[1].a.z,15)
            if selection==4:self.assertEqual(lua.globals().lines[1].b.x,4)

    def test_invalid_requests_never_enable_overlay_or_touch_owner_job(self):
        for seconds,selection in ((0,None),(-1,None),(121,None),(float('nan'),None),
                                  (90,'bad'),(90,0),(90,5),(90,1.5)):
            lua,m=self.runtime();self.assertFalse(m.show(seconds,selection)[0]);self.assertFalse(m.getStatus().enabled)
        for mutation in ("full.phase='stopped'","full.vehicleHitTest.phase='running'",'full.journalFailed=true',
                         'full.cleanupUnverified=true',"full.run=''",'paused=false','extensions.beamrt_vehiclePairProbe=nil',
                         'full.vehicleHitTest.results[4]=nil','debugDrawer.drawSphere=nil',
                         'full.vehicleHitTest.results[1].hit.point[1]=0/0',
                         'full.vehicleHitTest.results[1].hit.point[1]=3',
                         'full.vehicleHitTest.results[1].hit.distance=9999'):
            lua,m=self.runtime();lua.execute(mutation);self.assertFalse(m.show()[0],mutation)
            self.assertFalse(m.getStatus().enabled);self.assertEqual(len(lua.globals().lines),0)

    def test_snapshot_detached_from_status_mutation_and_status_legend_detached(self):
        lua,m=self.runtime();m.show();lua.execute('full.vehicleHitTest.results[1].hit.point[1]=99')
        m.onPreRender();self.assertEqual(lua.globals().spheres[2].point.x,2)
        status=m.getStatus();status.legend.hit='modified'
        self.assertNotEqual(m.getStatus().legend.hit,'modified')

    def test_run_owner_pause_and_pair_invalidity_stop_before_any_drawing(self):
        for mutation in ("full.run='new-run'","full.phase='stopped'",'paused=false',
                         'extensions.beamrt_vehiclePairProbe={getStatus=pair.getStatus}',
                         'full.cleanupUnverified=true',"full.vehicleHitTest.phase='running'"):
            lua,m=self.runtime();m.show();lua.execute(mutation);m.onPreRender()
            self.assertEqual(len(lua.globals().lines),0);self.assertEqual(len(lua.globals().spheres),0)
            self.assertFalse(m.getStatus().enabled,mutation)

    def test_compact_api_preferred_and_legacy_completed_pair_works_without_reload(self):
        lua,m=self.runtime();lua.execute('pair.getHitPreviewState=function()compactCalls=compactCalls+1;return full end')
        m.show();m.onPreRender();self.assertEqual(lua.globals().compactCalls,2)
        self.assertEqual(lua.globals().statusCalls,0)
        lua,m=self.runtime();m.show();m.onPreRender();self.assertEqual(lua.globals().statusCalls,2)
        self.assertTrue(m.getStatus().enabled)

    def test_hide_expiry_unload_reset_and_drawing_errors_drop_only_overlay(self):
        for action in ('hide','expired','unloaded','reset','destroyed','startMission','endMission','badDelta','drawError'):
            lua,m=self.runtime();m.show(1)
            if action=='hide':m.hide()
            elif action=='expired':m.onUpdate(1)
            elif action=='unloaded':m.onExtensionUnloaded()
            elif action=='reset':m.onVehicleResetted(41)
            elif action=='destroyed':m.onVehicleDestroyed(41)
            elif action=='startMission':m.onClientStartMission()
            elif action=='endMission':m.onClientEndMission()
            elif action=='badDelta':m.onUpdate(float('nan'))
            else:lua.execute("debugDrawer.drawLine=function()error('draw failed')end")
            m.onPreRender();self.assertFalse(m.getStatus().enabled)
            self.assertEqual(lua.globals().full.vehicleHitTest.phase,'complete')
            self.assertIsNone(m.getStatus().run)

    def test_failed_geometric_control_is_drawn_red_not_presented_as_reflection(self):
        lua,m=self.runtime();lua.execute('full.vehicleHitTest.results[1].controlPassed=false')
        self.assertTrue(m.show(30,1)[0]);m.onPreRender()
        self.assertEqual(lua.globals().lines[2].color.r,1);self.assertEqual(lua.globals().lines[2].color.g,.15)
        self.assertFalse(m.getStatus().opaqueVisibilityVerified)

    def test_actual_pair_integration_uses_finished_cpu_hits_without_new_native_calls(self):
        fixture=pair_test.VehiclePairProbe();lua,pair=fixture.runtime()
        lua.execute('for _,mesh in pairs(meshes)do mesh.positions={-3,-1,1,-3,1,1,-3,0,-1}end')
        self.assertTrue(pair.startHitTest()[0]);fixture.ready(lua);pair.update(.01)
        for _ in range(10):pair.update(.01)
        self.assertEqual(pair.getHitTestStatus().phase,'complete')
        lua.globals().extensions=lua.table_from({'beamrt_vehiclePairProbe':pair})
        lua.execute('''
        lines=0;spheres=0
        function vec3(x,y,z)return {x=x,y=y,z=z}end
        function ColorF(r,g,b,a)return {r=r,g=g,b=b,a=a}end
        debugDrawer={drawLine=function()lines=lines+1 end,drawSphere=function()spheres=spheres+1 end}
        ''')
        overlay=lua.execute((MODULES/'vehicleRayHitPreview.lua').read_text())
        self.assertTrue(overlay.show()[0]);overlay.onPreRender()
        self.assertEqual(lua.globals().lines,10);self.assertEqual(lua.globals().spheres,4)
        self.assertEqual(lua.globals().requests,2);self.assertEqual(lua.globals().freed,2)
        compact=pair.getHitPreviewState();self.assertIsNone(compact.vehicles)
        compact.vehicleHitTest.results[1].hit.point[1]=999
        self.assertNotEqual(pair.getHitPreviewState().vehicleHitTest.results[1].hit.point[1],999)
        lua.execute('cars[42].x=999');overlay.onPreRender()
        self.assertFalse(overlay.getStatus().enabled);self.assertEqual(lua.globals().lines,10)
        self.assertEqual(lua.globals().requests,2);self.assertEqual(lua.globals().freed,2)


if __name__=='__main__':unittest.main()
