"""Vehicle prop/electrics telemetry and live haze bindings, not GPU proof."""
import re
import unittest
import test_coherent_renderer as backend
import test_tuner_ui as tuner

GE=(backend.MODULES/'vehicleVolumes.lua').read_text()
VL=(backend.ROOT/'lua/vehicle/extensions/beamrtVehicleHaze.lua').read_text()
FIXTURE=r'''
camera={x=0,y=0,z=0};core_camera={getPosition=function()return camera end}
commands={};vehicles={};vehicleByID={}
function vehicle(id,x)
 local o={id=id,x=x or 10,props={}}
 function o:getID()return self.id end
 function o:getPosition()return {x=self.x,y=0,z=0}end
 function o:queueLuaCommand(cmd)commands[#commands+1]={id=self.id,command=cmd}end
 function o:getProp(pid)return self.props[pid]end
 function o:setPropLight()error('No light writes')end
 function o:setField()error('No vehicle writes')end
 for i=0,8 do
  local p={x=i,y=2,z=1,dir={x=0,y=1,z=0}}
  function p:getLiveTransformWorld()
   return {getColumn=function(_,i)if i==3 then return {x=p.x,y=p.y,z=p.z}end
     assert(i==1);return p.dir end}
  end
  o.props[i]=p
 end
 vehicleByID[id]=o;return o
end
vehicles={vehicle(41,10)}
be={getObjectCount=function()return #vehicles end,getObject=function(_,i)return vehicles[i+1]end,
 getObjectByID=function(_,id)return vehicleByID[id]end}
function packet(command)
 local literal,seq=command.command:match('sample%((.*),(%d+)%)')
 local token=assert(loadstring('return '..literal))()
 return {protocol=2,token=token,sequence=tonumber(seq),vehicleId=command.id,lights={}}
end
function lamp(pid,kind)
 return {pid=pid,kind=kind or 'spot',range=25,brightness=2,color={1,.8,.6},inner=40,outer=45}
end
'''


class VehicleHaze(unittest.TestCase):
    def runtimes(self):
        for lua,_ in backend.CoherentRenderer().runtimes():
            lua.execute(FIXTURE)
            m=lua.execute(GE);lua.globals().cars=m
            yield lua,m

    def respond(self,lua,lights='lamp(1)'):
        lua.execute('reply=packet(commands[#commands]);reply.lights={'+lights+'};__BeamRTVehicleHazeSink(reply)')

    def test_explicit_lifecycle_and_live_transform_including_vehicle_translation(self):
        for lua,m in self.runtimes():
            m.update(.1);self.assertEqual(len(lua.globals().commands),0)
            self.assertIsNone(lua.globals().__BeamRTVehicleHazeSink)
            self.assertTrue(m.enable());self.assertEqual(len(lua.globals().commands),0)
            m.update(.1);self.assertEqual(len(lua.globals().commands),1)
            self.respond(lua);m.update(0)
            self.assertEqual(m.getStatus().count,1)
            l=m.getLights()[1]
            self.assertEqual(list(l.position.values()),[11,2,1])
            self.assertEqual(list(l.direction.values()),[0,1,0])
            lua.execute('vehicles[1].x=20;vehicles[1].props[1].x=3;vehicles[1].props[1].dir={x=-2,y=0,z=0}')
            m.update(.016);l=m.getLights()[1]
            self.assertEqual(list(l.position.values()),[23,2,1])
            self.assertEqual(list(l.direction.values()),[-1,0,0])
            m.disable();self.assertEqual(m.getStatus().count,0)
            self.assertIsNone(lua.globals().__BeamRTVehicleHazeSink)

    def test_off_empty_response_stale_timeout_and_old_generation_never_reappear(self):
        for lua,m in self.runtimes():
            m.enable();m.update(.1);self.respond(lua);m.update(0)
            self.assertEqual(m.getStatus().count,1)
            lua.execute('old=reply')
            m.update(.11);self.respond(lua,'');m.update(0)
            self.assertEqual(m.getStatus().count,0)
            m.update(.11);self.respond(lua);m.update(0)
            self.assertEqual(m.getStatus().count,1)
            m.update(.36);self.assertEqual(m.getStatus().count,0)
            m.disable();m.enable();m.update(.1)
            lua.execute('__BeamRTVehicleHazeSink(old)');m.update(0)
            self.assertEqual(m.getStatus().count,0)

    def test_recycled_vehicle_identity_old_sequence_and_malformed_packet_are_rejected(self):
        for lua,m in self.runtimes():
            m.enable();m.update(.1);self.respond(lua);lua.execute('old=reply')
            lua.execute('vehicles={vehicle(41,5)}')
            m.update(.5)
            lua.execute('__BeamRTVehicleHazeSink(old)');m.update(0)
            self.assertEqual(m.getStatus().count,0)
            self.respond(lua,'lamp(100000000),lamp(2)');m.update(0)
            self.assertEqual(m.getStatus().count,1)
            m.update(.11)
            lua.execute('reply=packet(commands[#commands]);reply.lights={};for i=1,33 do reply.lights[i]=lamp(1)end;__BeamRTVehicleHazeSink(reply)')
            m.update(.36);self.assertEqual(m.getStatus().count,0)

    def test_four_source_budget_point_cone_and_invalid_values(self):
        for lua,m in self.runtimes():
            m.enable();m.update(.1)
            self.respond(lua,','.join('lamp('+str(i)+')' for i in range(1,9)))
            m.update(0);self.assertEqual(m.getStatus().count,4)
            m.update(.11);self.respond(lua,"lamp(1,'point')");m.update(0)
            self.assertEqual(m.getLights()[1].outer,-2)
            self.assertEqual(m.getLights()[1].inner,-1)
            self.assertEqual(list(m.getLights()[1].direction.values()),[0,0,0])
            m.update(.11)
            lua.execute('reply=packet(commands[#commands]);reply.lights={lamp(1),lamp(2),lamp(3)};reply.lights[1].color[1]=0/0;reply.lights[2].range=-1;reply.lights[3].outer=180;__BeamRTVehicleHazeSink(reply)')
            m.update(0);self.assertEqual(m.getStatus().count,0)

    def test_red_rear_sources_are_not_starved_by_bright_headlight_ranking(self):
        for lua,m in self.runtimes():
            m.enable();m.update(.1)
            lua.execute('''
            reply=packet(commands[#commands]);reply.lights={}
            for i=1,6 do local l=lamp(i);l.range=80;l.brightness=100;reply.lights[i]=l end
            for i=7,8 do local l=lamp(i);l.color={1,.1,.01};l.range=6;l.brightness=.0002;reply.lights[i]=l end
            __BeamRTVehicleHazeSink(reply)
            ''')
            m.update(0)
            self.assertEqual(m.getStatus().counts.redSelected,2)
            self.assertEqual(m.getStatus().count,4)
            self.assertEqual(m.getStatus().counts.redReported,2)
            for l in m.getLights().values():self.assertEqual(l.range,3 if l.red else 20)
            # The native/authored range was not written or replaced in telemetry.
            self.assertEqual(lua.globals().reply.lights[1].range,80)

    def test_coincident_beam_props_merge_without_merging_separate_lamps(self):
        for lua,m in self.runtimes():
            lua.execute('vehicles[1].props[2].x=vehicles[1].props[1].x+.01')
            m.enable();m.update(.1);self.respond(lua,'lamp(1),lamp(2),lamp(3)');m.update(0)
            self.assertEqual(m.getStatus().counts.merged,1)
            self.assertEqual(m.getStatus().count,2)
            self.assertTrue(m.setParameter('beamReach',10));m.update(0)
            self.assertEqual(m.getLights()[1].range,10)
            for key,value in [('beamReach',0),('haloReach',9),('beamReach',float('nan'))]:
                self.assertFalse(m.setParameter(key,value))
            m.disable();self.assertEqual(m.getStatus().counts.reported,0)

    def test_bounded_nearby_vehicles_callback_ownership_and_polling(self):
        for lua,m in self.runtimes():
            lua.execute('vehicles={};for i=1,8 do vehicles[i]=vehicle(40+i,i)end')
            m.enable();m.update(.1);self.assertEqual(len(lua.globals().commands),4)
            m.update(.01);self.assertEqual(len(lua.globals().commands),4)
            # Pending calls are bounded; no retry flood until 0.5 s timeout.
            for _ in range(20):m.update(.01)
            self.assertEqual(len(lua.globals().commands),4)
            m.disable()
            lua.execute('__BeamRTVehicleHazeSink=function()end;foreign=__BeamRTVehicleHazeSink')
            self.assertFalse(m.enable()[0]);m.disable()
            self.assertTrue(lua.eval('__BeamRTVehicleHazeSink==foreign'))

    def test_vehicle_only_rendering_toggle_and_shader_uploads(self):
        for lua,_ in self.runtimes():
            volume=lua.execute((backend.MODULES/'localVolumes.lua').read_text())
            self.assertTrue(volume.enable());volume.update(.1)
            self.respond(lua);volume.update(0)
            self.assertTrue(volume.getStatus().active)
            self.assertEqual(volume.getStatus().lightCount,0)
            self.assertEqual(lua.eval('objects.BeamRT_LocalVolumeFx._const["$vehicleCount"]'),1)
            self.assertEqual(lua.eval('objects.BeamRT_LocalVolumeFx._const["$vehiclePosition0"]'),'11 2 1 20')
            self.assertEqual(lua.eval('objects.BeamRT_LocalVolumeFx._const["$vehicleColor0"]'),'1 0.8 0.6 0.7')
            self.assertTrue(volume.setParameter('vehicleBeamReach',12));volume.update(0)
            self.assertEqual(lua.eval('objects.BeamRT_LocalVolumeFx._const["$vehiclePosition0"]'),'11 2 1 12')
            self.assertTrue(volume.setParameter('vehicleBeamGain',0));volume.update(0)
            self.assertFalse(volume.getStatus().active)
            self.assertTrue(volume.setParameter('vehicleBeamGain',.35));volume.update(0)
            self.assertTrue(volume.getStatus().active)
            volume.setVehicleEnabled(False);volume.update(.25)
            self.assertFalse(volume.getStatus().active)
            self.assertEqual(lua.eval('objects.BeamRT_LocalVolumeFx._const["$vehicleCount"]'),0)
            self.assertIsNone(lua.globals().__BeamRTVehicleHazeSink)
            volume.disable();self.assertFalse(volume.getStatus().vehicle.requested)

    def test_ui_is_inert_until_haze_enable_and_vehicle_toggle_has_independent_control(self):
        for lua,_ in self.runtimes():
            lua.execute(tuner.UI_MOCK)
            lua.globals().volume=lua.execute((backend.MODULES/'localVolumes.lua').read_text())
            lua.execute('''
            api.getLocalVolumeStatus=volume.getStatus
            api.setLocalVolumesEnabled=function(v)if v then return volume.enable()end;return volume.disable()end
            api.setVehicleVolumesEnabled=volume.setVehicleEnabled
            api.setLocalVolumeParameter=volume.setParameter
            tab='Lighting & GI';expanded=true
            ''')
            lua.globals().ui=lua.execute((backend.MODULES/'tunerUI.lua').read_text())
            lua.execute('ui.draw(im,api,panels)')
            self.assertEqual(len(lua.globals().commands),0)
            self.assertFalse(lua.globals().volume.getStatus().requested)
            lua.execute("click='Try local lamp haze##BeamRTVolumes';ui.draw(im,api,panels)")
            self.assertTrue(lua.globals().volume.getStatus().vehicle.requested)
            lua.execute("click='Vehicle light haze##BeamRTVehicleVolumes';ui.draw(im,api,panels)")
            self.assertFalse(lua.globals().volume.getStatus().vehicle.requested)
            self.assertTrue(lua.globals().volume.getStatus().requested)
            self.assertIsNone(lua.globals().__BeamRTVehicleHazeSink)


class VehicleSampler(unittest.TestCase):
    def runtimes(self):
        for lua,_ in backend.CoherentRenderer().runtimes():
            lua.execute('''
            lastCode=nil;electrics={values={lowbeam=1}};v={data={props={}}}
            obj={getID=function()return 41 end,queueGameEngineLua=function(_,s)lastCode=s end,
              setPropLight=function()error('No light writes')end}
            function serialize()return '{}'end
            function prop(pid,mesh)
              return {pid=pid,mesh=mesh or 'SPOTLIGHT',func='lowbeam',lightRange=30,
                lightColor={r=255,g=200,b=100},lightIntensityCd=10000}
            end
            v.data.props[0]=prop(0)
            ''')
            yield lua,lua.execute(VL)

    def test_authored_photometry_on_off_break_hide_and_scale_light(self):
        for lua,m in self.runtimes():
            p=m.sample('test',1)
            self.assertEqual(p.vehicleId,41);self.assertEqual(len(p.lights),1)
            self.assertEqual(p.lights[1].brightness,2)
            self.assertAlmostEqual(p.lights[1].color[2],200/255)
            self.assertIn('__BeamRTVehicleHazeSink',lua.globals().lastCode)
            lua.execute('electrics.values.lowbeam=0');self.assertEqual(len(m.sample('test',2).lights),0)
            lua.execute('electrics.values.lowbeam=1;v.data.props[0].disabled=true')
            self.assertEqual(len(m.sample('test',3).lights),0)
            lua.execute('v.data.props[0].disabled=false;v.data.props[0].hidden=true')
            self.assertEqual(len(m.sample('test',4).lights),0)
            lua.execute('v.data.props[0].hidden=false;v.data.props[0].scaleLight=true;electrics.values.lowbeam=.5')
            p=m.sample('test',5);self.assertEqual(p.lights[1].brightness,1)
            self.assertAlmostEqual(p.lights[1].color[2],170/255)

    def test_point_lumen_conversion_negative_nan_and_telemetry_caps(self):
        for lua,m in self.runtimes():
            lua.execute("v.data.props[0]=prop(0,'POINTLIGHT');v.data.props[0].lightIntensityLm=5000*4*math.pi")
            self.assertAlmostEqual(m.sample('test',1).lights[1].brightness,1)
            lua.execute('electrics.values.lowbeam=0/0')
            self.assertEqual(len(m.sample('test',2).lights),0)
            lua.execute('electrics.values.lowbeam=1;for i=0,100 do v.data.props[i]=prop(i)end')
            self.assertEqual(len(m.sample('test',3).lights),32)
            self.assertIsNone(m.sample('test',float('nan')))

    def test_red_props_survive_the_telemetry_budget_and_protocol_is_versioned(self):
        for lua,m in self.runtimes():
            lua.execute('''
            for i=0,80 do v.data.props[i]=prop(i)end
            v.data.props[81]=prop(81);v.data.props[81].lightColor={r=255,g=20,b=2}
            ''')
            result=m.sample('test',1)
            self.assertEqual(result.protocol,2)
            self.assertEqual(len(result.lights),32)
            self.assertIn(81,[l.pid for l in result.lights.values()])

if __name__=='__main__':unittest.main()
