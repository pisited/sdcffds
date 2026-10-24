"""Prepared geometry emitter discovery, read-only runtime and quadrature math.

Mocks cannot establish native mesh pivot/visual alignment or calibrated radiance.
"""
import json
from pathlib import Path
import sys
import unittest
import zlib
import test_coherent_renderer as backend
import test_tuner_ui as tuner

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import beamrt_emissive_prepare as prepare

FIXTURE=r'''
queries=0;reads=0;camera={x=0,y=0,z=3};source='abc';SOTStaticShape=2048
core_camera={getPosition=function()return camera end}
function vec3(x,y,z)return {x=x,y=y,z=z}end
function Box3F()return {setExtents=function()end,setCenter=function()end}end
function readFile(path)reads=reads+1;assert(path=='/levels/test/led.dae');return source end
material={___type='class<Material>',fields={mapTo='budynek_owlen_led',emissive='1',
 alphaTest='0',translucent='0',emissiveMap='/uniform_r.data.png',
 emissiveIntensityNits='3000',emissiveFactor='1 0 0',doubleSided='0'}}
function material:getField(k)return self.fields[k] end
function material:setField()error('No material writes allowed')end
objects.budynek_owlen_led=material
catalogue={schema='beamrt.emissive.quadrature.v1',assets={}}
local samples={}
for i=1,4 do samples[i]={v={{0,0,0},{1,0,0},{0,1,0}},triangleArea=.5,weightArea=.125}end
catalogue.assets['/levels/test/led.dae']={sourceBytes=3,sourceAdler32=38600999,
 emissiveMap='/uniform_r.data.png',groups={{material='budynek_owlen_led',samples=samples}}}
function jsonReadFile(path)assert(path=='/art/beamrt/emissive/catalog.json');return catalogue end
function instance(id,x)
 local o={id=id,shapeName='/levels/test/led.dae',x=x or 0,scale={x=1,y=1,z=1}}
 function o:getClassName()return 'TSStatic'end
 function o:getID()return self.id end
 function o:getName()return 'led'..self.id end
 function o:getScale()return self.scale end
 function o:getField(k)return self[k]end
 function o:setField()error('No TSStatic writes allowed')end
 function o:getTransform()
  local m={}
  function m:mulP3F(p)return vec3(p.x+o.x,p.y,p.z)end
  function m:getColumn(i)
   if i==3 then return vec3(o.x,0,0)end
   return vec3(i==0 and 1 or 0,i==1 and 1 or 0,i==2 and 1 or 0)
  end
  return m
 end
 objects[id]=o;return o
end
hits={instance(101,0)}
function findObjectList(box,mask)assert(mask==SOTStaticShape);queries=queries+1;return hits end
scenetree.findClassObjects=function(class)return class=='TSStatic' and hits or {} end
'''


class PreparedEmitters(unittest.TestCase):
    def runtimes(self):
        for lua,_ in backend.CoherentRenderer().runtimes():
            lua.execute(FIXTURE)
            module=lua.execute((backend.MODULES/'emissiveVolumes.lua').read_text())
            lua.globals().emit=module
            yield lua,module

    def test_opt_in_live_material_geometry_transform_and_disable(self):
        self.assertEqual(zlib.adler32(b'abc'),38600999)
        for lua,m in self.runtimes():
            m.update(1,lua.table());self.assertEqual(lua.globals().queries,0)
            self.assertFalse(m.getStatus().requested);self.assertEqual(m.getStatus().count,0)
            m.enable();self.assertEqual(lua.globals().queries,0)
            m.update(.5,lua.table());self.assertEqual(m.getStatus().count,1,m.getStatus().reason)
            e=m.getEmitters()[1]
            self.assertEqual(list(e.color.values()),[3000,0,0])
            self.assertAlmostEqual(e.samples[1].position[1],1/3)
            self.assertEqual(e.samples[1].normal[3],1)
            self.assertAlmostEqual(sum(s.area for s in e.samples.values()),.5)
            self.assertFalse(m.getStatus().shadowVisibility)
            self.assertFalse(m.getStatus().visualAlignmentVerified)
            lua.execute('hits[1].x=5;hits[1].scale=vec3(2,3,4)')
            m.update(.5,lua.table());e=m.getEmitters()[1]
            self.assertAlmostEqual(e.samples[1].position[1],5+2/3)
            self.assertAlmostEqual(sum(s.area for s in e.samples.values()),3)
            self.assertEqual(lua.globals().reads,1) # integrity cached only for this enable
            m.disable();self.assertEqual(m.getStatus().count,0)
            m.update(1,lua.table());self.assertEqual(m.getStatus().count,0)

    def test_unknown_disabled_translucent_ambiguous_and_modified_sources_are_rejected(self):
        commands=("material.fields.emissive='0'","material.fields.translucent='1'",
          "material.fields.alphaTest='1'","material.fields.emissiveIntensityNits='nan'",
          "material.fields.emissiveFactor='-1 0 0'","material.fields.emissiveMap='/different.png'",
          "material.fields.mapTo='other'","hits[1].shapeName='/levels/other.dae'",
          "source='abd'","hits[1].scale=vec3(0,1,1)",
          "catalogue.assets['/levels/test/led.dae'].groups[2]={}")
        for command in commands:
            for lua,m in self.runtimes():
                lua.execute(command);m.enable();m.update(.5,lua.table())
                self.assertEqual(m.getStatus().count,0,command)

    def test_bounded_selection_native_duplicate_suppression_and_distant_rejection(self):
        for lua,m in self.runtimes():
            lua.execute('hits={};for i=1,150 do hits[i]=instance(100+i,i)end')
            m.enable();m.update(.5,lua.table())
            self.assertEqual(m.getStatus().count,2)
            self.assertEqual(m.getEmitters()[1].id,101)
            # Near matching red native source suppresses this geometry contribution.
            lua.execute('hits={instance(101,0)};native={{position={1/3,1/3,0},color={1,0,0}}}')
            m.disable();m.enable()
            m.update(.5,lua.globals().native);self.assertEqual(m.getStatus().count,0)
            lua.execute('native[1].color={0,1,0}')
            m.update(.5,lua.globals().native);self.assertEqual(m.getStatus().count,1)
            lua.execute('camera.x=1000')
            m.update(.01,lua.table());self.assertEqual(m.getStatus().count,0)

    def test_incremental_scan_finds_led_after_first_128_even_without_spatial_api(self):
        for lua,m in self.runtimes():
            lua.execute('''
            findObjectList=nil;SOTStaticShape=nil;hits={}
            for i=1,300 do local o=instance(100+i,i);o.shapeName='/unknown.dae';hits[i]=o end
            hits[301]=instance(999,0)
            ''')
            m.enable();m.update(.016,lua.table())
            self.assertEqual(m.getStatus().count,0)
            self.assertGreater(m.getStatus().discovery.pending,0)
            for _ in range(20):m.update(.016,lua.table())
            self.assertEqual(m.getStatus().count,1,m.getStatus().reason)
            self.assertGreaterEqual(m.getStatus().discovery.inspected,301)
            self.assertEqual(m.getStatus().discovery.pending,0)

    def test_rejection_diagnostics_visibility_and_live_instance_emission(self):
        for lua,m in self.runtimes():
            lua.execute('''
            material.fields.emissive=1;material.fields.alphaTest=0;material.fields.translucent=0
            material.fields.instanceEmissive='1';hits[1].instanceColor='0 0 0 1'
            ''')
            m.enable();m.update(.5,lua.table())
            self.assertEqual(m.getStatus().count,0)
            self.assertEqual(m.getStatus().discovery.rejected.instanceColor,1)
            lua.execute("hits[1].instanceColor='.5 1 1 1'")
            m.update(.5,lua.table());self.assertEqual(m.getStatus().count,1)
            self.assertEqual(m.getEmitters()[1].color[1],1500)
            lua.execute('hits[1].isRenderEnabled=function()return false end')
            m.update(.5,lua.table());self.assertEqual(m.getStatus().count,0)
            self.assertEqual(m.getStatus().discovery.rejected.hidden,1)
            lua.execute("hits[1].isRenderEnabled=nil;material.fields.alphaTest=1")
            m.update(.5,lua.table());self.assertEqual(m.getStatus().discovery.rejected.material,1)
            self.assertIn('alphaTest=1',m.getStatus().reason)

    def test_local_volume_integration_resets_on_restart_and_supports_emitters_without_spots(self):
        for lua,_ in self.runtimes():
            v=lua.execute((backend.MODULES/'localVolumes.lua').read_text())
            self.assertFalse(v.setEmissiveEnabled(True)[0])
            self.assertTrue(v.enable());v.update(.5)
            self.assertFalse(v.getStatus().emissive.requested)
            self.assertFalse(v.getStatus().active)
            self.assertTrue(v.setEmissiveEnabled(True));v.update(.5)
            self.assertTrue(v.getStatus().active,v.getStatus().reason)
            self.assertEqual(v.getStatus().emissive.count,1)
            self.assertEqual(lua.eval('objects.BeamRT_LocalVolumeFx._const["$emitterCount"]'),1)
            self.assertEqual(lua.eval('objects.BeamRT_LocalVolumeFx._const["$volumeCount"]'),0)
            v.setParameter('emissiveGain',0);v.update(.5);self.assertFalse(v.getStatus().active)
            v.setParameter('emissiveGain',1);v.update(.5);self.assertTrue(v.getStatus().active)
            v.setEmissiveEnabled(False);v.update(.5);self.assertFalse(v.getStatus().active)
            v.setEmissiveEnabled(True);v.update(.5);self.assertTrue(v.getStatus().active)
            v.disable();v.enable();v.update(.5)
            self.assertFalse(v.getStatus().emissive.requested)
            self.assertEqual(lua.eval('objects.BeamRT_LocalVolumeFx._const["$emitterCount"]'),0)

    def test_emissive_ui_does_not_start_on_open_and_requires_its_own_click(self):
        for lua,_ in self.runtimes():
            lua.execute(tuner.UI_MOCK)
            lua.globals().volume=lua.execute((backend.MODULES/'localVolumes.lua').read_text())
            lua.execute('''
            api.getLocalVolumeStatus=volume.getStatus
            api.setLocalVolumesEnabled=function(v)if v then return volume.enable()end;return volume.disable()end
            api.setEmissiveVolumesEnabled=volume.setEmissiveEnabled
            api.setLocalVolumeParameter=volume.setParameter
            tab='Lighting & GI';expanded=true
            ''')
            lua.globals().ui=lua.execute((backend.MODULES/'tunerUI.lua').read_text())
            lua.execute('ui.draw(im,api,panels)')
            self.assertFalse(lua.globals().volume.getStatus().requested)
            lua.execute("click='Try local lamp haze##BeamRTVolumes';ui.draw(im,api,panels)")
            self.assertTrue(lua.globals().volume.getStatus().requested)
            self.assertFalse(lua.globals().volume.getStatus().emissive.requested)
            lua.execute("click='Prepared LED emissive haze (experimental)##BeamRTEmissive';ui.draw(im,api,panels)")
            self.assertTrue(lua.globals().volume.getStatus().emissive.requested)


class QuadraturePreparation(unittest.TestCase):
    def test_area_weighting_preserves_total_and_uses_real_triangle_coordinates(self):
        a=[[0,0,0],[1,0,0],[0,1,0]];b=[[5,0,0],[7,0,0],[5,2,0]]
        groups=prepare.quadrature([{'v':v,'materialNameCandidate':'led'} for v in (a,b)])
        self.assertEqual(len(groups),1);self.assertEqual(groups[0]['area'],2.5)
        self.assertEqual(sum(s['weightArea'] for s in groups[0]['samples']),2.5)
        self.assertEqual(len(groups[0]['samples']),4)
        self.assertTrue(all(s['v'] in (a,b) for s in groups[0]['samples']))

    def test_invalid_geometry_and_missing_material_fail(self):
        for v in ([[0,0,0],[1,float('nan'),0],[0,1,0]],[[0,0,0]]):
            with self.assertRaises(ValueError):prepare.area(v)
        with self.assertRaises(ValueError):prepare.quadrature([{'v':[[0,0,0]]}])

    def test_catalogue_is_bounded_verified_asset_scope_not_an_arbitrary_bright_pixel_list(self):
        c=json.loads((backend.ROOT/'art/beamrt/emissive/catalog.json').read_text())
        self.assertEqual(c['schema'],'beamrt.emissive.quadrature.v1')
        self.assertEqual(len(c['assets']),2)
        self.assertFalse(c['sourceTextureSampling']);self.assertFalse(c['visualAlignmentVerified'])
        for desc in c['assets'].values():
            self.assertEqual(len(desc['groups']),1)
            self.assertEqual(desc['groups'][0]['material'],'budynek_owlen_led')
            self.assertEqual(len(desc['groups'][0]['samples']),4)
            self.assertGreater(desc['sourceBytes'],0)
            self.assertEqual(len(desc['sourceSHA256']),64)

if __name__=='__main__':unittest.main()
