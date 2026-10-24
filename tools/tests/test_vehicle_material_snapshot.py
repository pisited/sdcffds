"""Native field contract + reflected factor preview, using synthetic geometry."""
import unittest
import struct
import test_vehicle_camera_reflection as camera_fixture
import test_vehicle_ray_image as image_fixture

MATERIALS=r'''
materialReads=0;fieldFailure=false
materialFields={version='1.5',activeLayers='1',diffuseColor='0.8 0.2 0.1 1',
 baseColorFactor='0.8 0.2 0.1 1',roughnessFactor='0.3',metallicFactor='0.7',
 alphaTest='0',translucent='0',diffuseMap='vehicles/test/body.color.dds',
 colorPaletteMap='vehicles/test/body.palette.dds',instanceDiffuse='1',vertColor='0'}
material={___type='class<Material>'}
function material:getField(name,layer)
 assert(layer==0);materialReads=materialReads+1
 if fieldFailure then error('fake native getter error')end
 return materialFields[name] or ''
end
scenetree={findObject=function(name)
 if name=='unknown' or name=='test_body'then return material end
end}
'''


def runtime():
    lua=camera_fixture.runtime();lua.execute(MATERIALS)
    lua.execute("for _,s in ipairs(scenes)do for _,r in ipairs(s.ranges)do r.materialName='unknown'end end")
    m=lua.execute((camera_fixture.bounce_fixture.bvh_fixture.MODULES/'vehicleMaterialSnapshot.lua').read_text())
    lua.globals().package.loaded['ge/extensions/beamrt/vehicleMaterialSnapshot']=m
    lua.globals().materials=m
    return lua


class VehicleMaterialSnapshot(unittest.TestCase):
    def test_live_layer_zero_field_contract_detached_snapshot_and_alias_fallback(self):
        lua=runtime();m=lua.globals().materials;s=m.capture(lua.globals().scenes)
        self.assertEqual((len(s.names),s.resolved,s.factors),(1,1,1))
        r=s.records[1]
        self.assertEqual(r.factorField,'diffuseColor');self.assertEqual(r.color[1],.8)
        self.assertEqual(r.roughness[1],.3);self.assertEqual(r.metallic[1],.7)
        self.assertTrue(r.textureDependent);self.assertTrue(r.instanceDependent)
        self.assertEqual(r.coverage,'declared-opaque')
        lua.execute("materialFields.diffuseColor='0.4 0.4 0.4 1'")
        self.assertEqual(r.color[1],.8);self.assertFalse(m.matches(s)[0])
        lua.execute('materialFields.diffuseColor=nil')
        new=m.capture(lua.globals().scenes)
        self.assertEqual(new.records[1].factorField,'baseColorFactor')
        self.assertEqual(new.records[1].color[1],.8)
        # Snapshot serialization must contain no native wrapper/functions.
        lua.globals().snapshot=s
        lua.execute('''
        local function plain(t)for k,v in pairs(t)do
          assert(type(v)~='function' and type(v)~='userdata' and type(v)~='cdata')
          if type(v)=='table'then plain(v)end
        end end
        plain(snapshot)
        ''')

    def test_unknown_material_bad_class_failed_fields_and_conflicts_have_explicit_fallback(self):
        for mutation in (
            'scenetree=nil',
            "scenetree.findObject=function()return nil end",
            "material.___type='class<CustomMaterial>'",
            'fieldFailure=true',
            "materialFields.baseColorFactor='0 0 1 1'",
            "materialFields.diffuseColor='nan 0 0 1';materialFields.baseColorFactor=nil",
            "materialFields.diffuseColor='1e309 0 0 1';materialFields.baseColorFactor=nil",
            "materialFields.diffuseColor='-1 0 0 1';materialFields.baseColorFactor=nil",
            "materialFields.diffuseColor='1 junk 0 1';materialFields.baseColorFactor=nil",
            "materialFields.diffuseMap=string.rep('x',2049)",
        ):
            lua=runtime();lua.execute(mutation);m=lua.globals().materials;s=m.capture(lua.globals().scenes)
            self.assertEqual(s.factors,0,mutation)
            p,kind=m.pixel(s,lua.table_from({'materialName':'unknown'}))
            self.assertEqual(kind,'unknown');self.assertEqual(tuple(p.values()),(175,85,220))

    def test_native_class_legacy_fallback_does_not_override_known_wrong_class(self):
        lua=runtime();m=lua.globals().materials
        lua.execute("material.___type=nil;material.getClassName=function()return 'Material'end")
        self.assertEqual(m.capture(lua.globals().scenes).factors,1)
        lua.execute("material.___type='class<CustomMaterial>'")
        self.assertEqual(m.capture(lua.globals().scenes).factors,0)

    def test_live_beamng_stock_color_strings_and_rgb_follow_installed_editor_contract(self):
        lua=runtime();m=lua.globals().materials
        lua.execute('''
        white={1,1,1,1};black={0,0,0,1};stockCalls=0
        function getStockColor(name)
          stockCalls=stockCalls+1
          if name=='White'then return white elseif name=='black'then return black end
        end
        materialFields.diffuseColor='White';materialFields.baseColorFactor='1 1 1 1'
        ''')
        s=m.capture(lua.globals().scenes);r=s.records[1]
        self.assertTrue(r.factorAvailable);self.assertEqual(r.colorEncoding,'native-stock-color')
        self.assertEqual(tuple(r.color.values()),(1,1,1,1))
        self.assertEqual(lua.globals().stockCalls,1)
        status=m.status(s);self.assertEqual(status.records[1].rawDiffuseColor,'White')
        r.color[1]=.2;self.assertEqual(lua.globals().white[1],1)
        lua.execute("materialFields.diffuseColor='black';materialFields.baseColorFactor='black'")
        s=m.capture(lua.globals().scenes)
        self.assertEqual(tuple(s.records[1].color.values()),(0,0,0,1))
        self.assertEqual(lua.globals().black[4],1)
        lua.execute("materialFields.diffuseColor='0.3 0.2 0.1';materialFields.baseColorFactor='0.3 0.2 0.1 1'")
        r=m.capture(lua.globals().scenes).records[1]
        self.assertTrue(r.factorAvailable);self.assertEqual(r.colorEncoding,'numeric-rgb')
        self.assertEqual(tuple(r.color.values()),(.3,.2,.1,1))

    def test_unknown_stock_color_missing_lookup_bad_native_results_never_default_white(self):
        for lookup in (
            'getStockColor=nil',
            'getStockColor=function()return nil end',
            "getStockColor=function()error('native lookup error')end",
            'getStockColor=function()return {1,1,1}end',
            'getStockColor=function()return {1,0/0,1,1}end',
            'getStockColor=function()return {1,1,1,2}end',
            "getStockColor=function()return 'White'end",
        ):
            lua=runtime();lua.execute("materialFields.diffuseColor='White';materialFields.baseColorFactor=nil;"+lookup)
            s=lua.globals().materials.capture(lua.globals().scenes)
            self.assertEqual(s.factors,0,lookup)
        lua=runtime();lua.execute('''
        getStockColor=function()error('Numeric values must not use stock lookup')end
        materialFields.diffuseColor='0.2 0.3 0.4 1'
        materialFields.baseColorFactor='0.2 0.3 0.4 1'
        ''')
        self.assertEqual(lua.globals().materials.capture(lua.globals().scenes).factors,1)

    def test_stock_palette_changes_reject_snapshot_even_when_field_names_stay_equal(self):
        lua=runtime();lua.execute('''
        stock={1,1,1,1}
        getStockColor=function()return stock end
        materialFields.diffuseColor='White';materialFields.baseColorFactor='White'
        ''')
        m=lua.globals().materials;s=m.capture(lua.globals().scenes)
        lua.execute('stock[1]=.5')
        ok,why=m.matches(s)
        self.assertFalse(ok);self.assertIn('Resolved material color changed',why)

    def test_named_colors_remain_unknown_when_aliases_resolve_to_different_values(self):
        lua=runtime();lua.execute('''
        getStockColor=function(name)return name=='White'and {1,1,1,1}or {0,0,0,1}end
        materialFields.diffuseColor='White';materialFields.baseColorFactor='black'
        ''')
        r=lua.globals().materials.capture(lua.globals().scenes).records[1]
        self.assertFalse(r.factorAvailable);self.assertEqual(r.reason,'conflicting color factor aliases')

    def test_factor_lighting_uses_secondary_geometric_normal_and_distinguishes_unknown_from_miss(self):
        lua=runtime();m=lua.globals().materials;s=m.capture(lua.globals().scenes)
        for normal in ([1,0,0],[-1,0,0],[0,0,1]):
            p,kind=m.pixel(s,lua.table_from({'materialName':'unknown','normal':lua.table_from(normal)}))
            self.assertEqual(kind,'factor')
            shade=.2+.8*abs(sum(a*b for a,b in zip(normal,(.36,-.48,.8))))
            self.assertEqual(tuple(p.values()),tuple(int(c*shade*255+.5)for c in (.8,.2,.1)))
        p,kind=m.pixel(s,None)
        self.assertEqual(kind,'miss');self.assertEqual(tuple(p.values()),(58,68,82))

    def test_field_edits_reject_publication_and_unknown_texture_inputs_stay_unknown(self):
        for mutation in ("materialFields.roughnessFactor='0.8'",
                         "materialFields.colorPaletteMap='changed.dds'",
                         "materialFields.activeLayers='2'",
                         "scenetree.findObject=function()return nil end"):
            lua=runtime();m=lua.globals().materials;s=m.capture(lua.globals().scenes)
            lua.execute(mutation);self.assertFalse(m.matches(s)[0])
        lua=runtime();m=lua.globals().materials;s=m.capture(lua.globals().scenes)
        self.assertFalse(s.texturesSampled);self.assertFalse(s.paintPaletteSampled)
        lua.execute("materialFields.alphaTest='1';materialFields.activeLayers='2'")
        r=m.capture(lua.globals().scenes).records[1]
        self.assertTrue(r.layered);self.assertEqual(r.coverage,'unverified')

    def test_real_bounce_material_panels_match_identity_geometry_and_negative_control(self):
        lua=runtime();s=lua.globals().vehicleCameraSnapshot.capture()
        job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'camera-material',s))
        status=lua.globals().image.status(job)
        self.assertEqual((status.width,status.height,status.viewCount),(256,128,4))
        self.assertEqual(status.pixelsRendered,32768)
        self.assertTrue(status.cameraBounceGeometricControlsPassed)
        self.assertTrue(status.materialSnapshotMatched);self.assertTrue(status.materialFactorPreview)
        self.assertGreater(status.reflectedFactorPixels,0)
        self.assertEqual(status.reflectedUnknownMaterialPixels,0)
        self.assertEqual(status.materials.factors,1)
        self.assertTrue(status.materials.textureDependent)
        for key in ('textureColorsSampled','paintPaletteSampled','receiverBRDFApplied','roughnessApplied',
                    'sceneLightingUsed','materialShadingVerified','gpuExecutionVerified','offscreenReflectionTestPassed'):
            self.assertFalse(status[key],key)
        positives=0
        for y in range(64):
            for x in range(128):
                mask=job.pixels[y*256+x+1]
                full=job.pixels[y*256+x+129];excluded=job.pixels[(y+64)*256+x+129]
                if mask.reflectedVehicleId==42:
                    positives+=1
                    self.assertEqual(full.reflectedMaterialName,'unknown')
                    self.assertIsNone(excluded.reflectedMaterialName)
                    self.assertNotEqual(tuple(full[i]for i in (1,2,3)),tuple(excluded[i]for i in (1,2,3)))
        self.assertEqual(positives,status.otherHitsA)

    def test_material_changes_while_rendering_cancel_without_complete_image(self):
        lua=runtime();lua.execute('image.operationsPerUpdate=32')
        s=lua.globals().vehicleCameraSnapshot.capture()
        job=lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'camera-material',s)
        for _ in range(10000):
            lua.globals().image.advance(job,.001)
            if job.phase=='rendering-bounces':break
        self.assertEqual(job.phase,'rendering-bounces')
        lua.execute("materialFields.roughnessFactor='0.9'")
        with self.assertRaisesRegex(Exception,'Material field changed'):image_fixture.finish(lua,job)
        self.assertNotEqual(job.phase,'complete')
        lua.globals().image.cancel(job)
        self.assertIsNone(job.materialSnapshot);self.assertIsNone(job.co);self.assertEqual(len(job.pixels),0)

    def test_reflection_uses_secondary_material_not_receivers_color_or_vehicle_tint(self):
        lua=runtime();lua.execute('''
        scenes[1].ranges[1].materialName='red_receiver'
        scenes[2].ranges[1].materialName='blue_source'
        scenetree.findObject=function(name)
          if name~='red_receiver' and name~='blue_source'then return nil end
          return {___type='class<Material>',getField=function(_,field,layer)
            assert(layer==0)
            if field=='diffuseColor' then return name=='red_receiver' and '1 0 0 1' or '0 0 1 1' end
            return ''
          end}
        end
        ''')
        s=lua.globals().vehicleCameraSnapshot.capture()
        job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'camera-material',s))
        positives=0
        for y in range(64):
            for x in range(128):
                mask=job.pixels[y*256+x+1];p=job.pixels[y*256+x+129]
                if mask.reflectedVehicleId==42:
                    positives+=1
                    self.assertEqual(p.reflectedMaterialName,'blue_source')
                    self.assertEqual((p[1],p[2]),(0,0));self.assertGreater(p[3],0)
        self.assertGreater(positives,0)
        status=lua.globals().image.materialStatus(job)
        status.records[1].color[1]=999
        self.assertNotEqual(lua.globals().image.materialStatus(job).records[1].color[1],999)

    def test_material_identity_budget_refuses_instead_of_truncating(self):
        lua=runtime();lua.execute('''
        many={{ranges={}}}
        for i=1,513 do many[1].ranges[i]={materialName='material'..i}end
        ''')
        with self.assertRaisesRegex(Exception,'budget exceeded'):
            lua.globals().materials.capture(lua.globals().many)

    def test_bitmap_preserves_four_panel_pixels_and_maximum_output_budget(self):
        lua=runtime();lua.execute('cam.height=960;view.viewPort.extent.y=960')
        s=lua.globals().vehicleCameraSnapshot.capture()
        job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'camera-material',s))
        self.assertEqual((job.width,job.height),(256,192));self.assertEqual(job.pixelsRendered,49152)
        lua.globals().job=job
        get=lua.eval('function(a,b)local s=image.bitmap(job);return {string.byte(s,a,b)}end')
        data=bytearray();size=54+256*192*3
        for start in range(1,size+1,4096):data.extend(get(start,min(size,start+4095)).values())
        self.assertEqual(struct.unpack_from('<ii',data,18),(256,192))
        self.assertEqual(struct.unpack_from('<I',data,2)[0],len(data))
        for x,y in ((0,0),(64,48),(192,48),(64,144),(192,144),(255,191)):
            offset=54+(191-y)*768+x*3;b,g,r=data[offset:offset+3]
            self.assertEqual((r,g,b),tuple(job.pixels[y*256+x+1][i]for i in (1,2,3)))

    def test_ui_draws_all_four_panels_and_balances_begin_end_on_error(self):
        lua=runtime();s=lua.globals().vehicleCameraSnapshot.capture()
        job=image_fixture.finish(lua,lua.globals().image.create(lua.globals().scenes,lua.globals().poses,'camera-material',s))
        lua.execute('''
        begins=0;ends=0;rects=0;labels={}
        ui_imgui={Cond_FirstUseEver=1,ImVec2=function(x,y)return {x=x,y=y}end,
          SetNextWindowSize=function()end,Begin=function()begins=begins+1;return true end,
          End=function()ends=ends+1 end,TextUnformatted=function(t)labels[#labels+1]=t end,
          GetCursorScreenPos=function()return {x=0,y=0}end,GetWindowDrawList=function()return {}end,
          GetContentRegionAvailWidth=function()return 512 end,
          ImDrawList_AddRectFilled=function()rects=rects+1 end,Dummy=function()end}
        ''')
        lua.globals().image.draw(job)
        self.assertEqual(lua.globals().begins,1);self.assertEqual(lua.globals().ends,1)
        self.assertGreater(lua.globals().rects,0)
        self.assertTrue(any('RIGHT reflected material' in label for label in lua.globals().labels.values()))
        lua.execute("ui_imgui.ImDrawList_AddRectFilled=function()error('draw failure')end")
        with self.assertRaisesRegex(Exception,'draw failure'):lua.globals().image.draw(job)
        self.assertEqual(lua.globals().begins,2);self.assertEqual(lua.globals().ends,2)

    def test_controller_reads_materials_only_after_both_native_handles_are_freed(self):
        lua,p=camera_fixture.VehicleCameraReflection().pair_runtime();lua.execute(MATERIALS)
        lua.execute('''
        local get=material.getField
        function material:getField(...)assert(freed==2);return get(self,...)end
        ''')
        self.assertTrue(p.startMaterialReflectionTest()[0]);self.assertEqual(lua.globals().materialReads,0)
        lua.execute('meshes[41].dataIsReady=true;meshes[42].dataIsReady=true')
        for _ in range(4000):
            p.update(.001)
            if p.getImageStatus().phase in ('complete','cancelled'):break
        status=p.getImageStatus();self.assertEqual(status.phase,'complete',status.reason)
        self.assertEqual(status.profile,'camera-material');self.assertIn('camera-material-',status.file)
        self.assertTrue(status.materialSnapshotMatched);self.assertEqual(status.materials.factors,1)
        records=p.getMaterialStatus().records
        self.assertEqual(len(records),1);self.assertEqual(records[1].name,'test_body')
        self.assertEqual(lua.globals().requests,2);self.assertEqual(lua.globals().freed,2)
        self.assertGreater(lua.globals().materialReads,0)
        p.stop();self.assertEqual(lua.globals().freed,2)


if __name__=='__main__':unittest.main()
