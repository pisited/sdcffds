"""Offline geometry/transform contracts. No in-game rendering claims."""
import json
import math
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import beamrt_scene_align as align
import beamrt_scene_import as mesh


def document(node, unit=1., up='Z_UP'):
    root=ET.fromstring(mesh.SAMPLE)
    asset=mesh.first(root,'asset')
    mesh.first(asset,'unit').set('meter',str(unit))
    mesh.first(asset,'up_axis').text=up
    ns='{http://www.collada.org/2005/11/COLLADASchema}'
    scene=ET.SubElement(root,ns+'library_visual_scenes')
    visual=ET.SubElement(scene,ns+'visual_scene',{'id':'scene'})
    visual.append(ET.fromstring(node))
    link=ET.SubElement(root,ns+'scene')
    ET.SubElement(link,ns+'instance_visual_scene',{'url':'#scene'})
    return root


class TransformTests(unittest.TestCase):
    def faces(self,node,**kwargs):
        return align.extract_selected(document(node,**kwargs),'selected')[0]
    def test_parent_child_transform_order_and_scale(self):
        faces=self.faces('<node id="parent"><translate>10 20 30</translate><rotate>0 0 1 90</rotate>'
          '<node id="selected"><translate>2 0 0</translate><scale>2 3 4</scale><instance_geometry url="#wall"/></node></node>')
        expected=[[10,22,30],[10,24,30],[10,24,38]]
        for actual,want in zip(faces[0]['v'],expected):
            for a,b in zip(actual,want):self.assertAlmostEqual(a,b)
    def test_matrix_translation_row_major(self):
        faces=self.faces('<node id="selected"><matrix>1 0 0 7 0 1 0 8 0 0 1 9 0 0 0 1</matrix><instance_geometry url="#wall"/></node>')
        self.assertEqual(faces[0]['v'][0],[7,8,9])
    def test_units_and_axes_apply_after_node_translation(self):
        faces=self.faces('<node id="selected"><translate>0 100 0</translate><instance_geometry url="#wall"/></node>',unit=.01,up='Y_UP')
        self.assertEqual(faces[0]['v'][0],[0,0,1])
    def test_one_lod_only_collision_and_sibling_excluded(self):
        root=document('<node id="parent"><node id="collision"><instance_geometry url="#wall"/></node>'
          '<node id="selected"><instance_geometry url="#wall"/></node>'
          '<node id="lowLOD"><instance_geometry url="#wall"/></node></node>')
        faces,meta=align.extract_selected(root,'selected')
        self.assertEqual(len(faces),2);self.assertEqual(meta['ancestry'],['parent','selected'])
    def test_geometry_provenance_preserved(self):
        faces=self.faces('<node id="selected"><instance_geometry url="#wall"/></node>')
        self.assertEqual(faces[0]['geometryId'],'wall')
        self.assertEqual(faces[0]['nodePath'],['selected'])
        self.assertEqual(faces[0]['alphaMode'],'unknown')
    def test_native_basis_applies_translation_rotation_nonuniform_scale(self):
        faces=self.faces('<node id="selected"><instance_geometry url="#wall"/></node>')
        basis={'origin':[100,200,300],'x':[0,2,0],'y':[-3,0,0],'z':[0,0,.5]}
        result=align.bake_basis(faces,basis)
        self.assertEqual(result[0]['v'],[[100,200,300],[100,202,300],[100,202,301]])
        self.assertEqual(faces[0]['v'][0],[0,0,0])
    def test_unsupported_transform_and_missing_node_fail(self):
        with self.assertRaises(ValueError):self.faces('<node id="selected"><skew>1 0 0 0 1 0 0</skew><instance_geometry url="#wall"/></node>')
        with self.assertRaises(ValueError):align.extract_selected(document('<node id="other"/>'),'selected')
    def test_duplicate_node_and_nonaffine_fail(self):
        with self.assertRaises(ValueError):self.faces('<node id="parent"><node id="selected"/><node id="selected"/></node>')
        with self.assertRaises(ValueError):self.faces('<node id="selected"><matrix>1 0 0 0 0 1 0 0 0 0 1 0 1 0 0 1</matrix></node>')
    def test_active_visual_scene_required(self):
        with self.assertRaises(ValueError):align.extract_selected(ET.fromstring(mesh.SAMPLE),'selected')
    def test_caps_and_path_rejection(self):
        with self.assertRaises(ValueError):align.extract_selected(document('<node id="selected"><instance_geometry url="#wall"/></node>'),'selected',1)
        with self.assertRaises(ValueError):align.asset_name('../outside.dae')
        with self.assertRaises(ValueError):align.asset_name('shape.cdae')
    def test_selected_instance_material_binding(self):
        faces=self.faces('<node id="selected"><instance_geometry url="#wall"><bind_material><technique_common>'
          '<instance_material symbol="wallpaint" target="#wallMaterial"/></technique_common></bind_material></instance_geometry></node>')
        self.assertEqual(faces[0]['materialNameCandidate'],'wallMaterial')
    def test_archive_read_only_output_and_material_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            p=Path(temporary);zpath=p/'input.zip'
            root=document('<node id="selected"><instance_geometry url="#wall"><bind_material><technique_common>'
              '<instance_material symbol="wallpaint" target="#paint"/></technique_common></bind_material></instance_geometry></node>')
            with zipfile.ZipFile(zpath,'w') as z:
                z.writestr('levels/test/wall.dae',ET.tostring(root))
                z.writestr('levels/test/main.materials.json',json.dumps({'paint':{'class':'Material','mapTo':'paint','Stages':[{'opacityMap':'a.png'}]}}))
            before=zpath.read_bytes()
            package=align.prepare(zpath,'levels/test/wall.dae','selected',p/'out.json')
            self.assertEqual(before,zpath.read_bytes())
            self.assertFalse(package['gpuUploaded']);self.assertFalse(package['alignmentVerified'])
            self.assertEqual(package['materials']['paint']['candidates'][0]['alphaCandidate'],'needs-alpha-test')
            self.assertEqual(package['materials']['paint']['alphaMode'],'unknown')
            self.assertEqual(package['bvh']['triangleIndices'],[0,1])
    def test_bvh_contains_all_faces_and_children_bounds(self):
        faces=[{'v':[[float(i),0,0],[float(i)+.8,0,0],[float(i),1,0]]} for i in range(39)]
        bvh=mesh.build_bvh(faces)
        self.assertEqual(sorted(bvh['triangleIndices']),list(range(39)))
        for node in bvh['nodes']:
            if node['count']:
                self.assertLessEqual(node['count'],8)
            else:
                for index in (node['left'],node['right']):
                    child=bvh['nodes'][index]
                    for i in range(3):
                        self.assertGreaterEqual(child['min'][i],node['min'][i])
                        self.assertLessEqual(child['max'][i],node['max'][i])
    def test_negative_uv_index_rejected(self):
        root=ET.fromstring(mesh.SAMPLE)
        geom=next(mesh.descendants(root,'mesh'))
        uv=ET.SubElement(geom,'source',{'id':'uv'})
        ET.SubElement(uv,'float_array').text='0 0 1 0 1 1'
        common=ET.SubElement(uv,'technique_common');ET.SubElement(common,'accessor',{'count':'3','stride':'2'})
        tri=mesh.first(geom,'triangles');ET.SubElement(tri,'input',{'semantic':'TEXCOORD','source':'#uv','offset':'1'})
        mesh.first(tri,'p').text='0 -1 1 1 2 2'
        faces,warnings=mesh.parse_geometry(geom,'wall',{},1,'Z_UP',10)
        self.assertEqual(faces,[]);self.assertEqual(warnings['bad source index'],1)


if __name__=='__main__':unittest.main(verbosity=2)
