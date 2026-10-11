import sys
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import beamrt_underground_prepare as prepare

def source(kind):
    return '''#include "convexGeometry.h.hlsl"
LightBufferOutput main(ConvexConnectP IN)
{
    const float3 worldPos = perspectiveDiv(mul(cb.screenToWorld, float4(posNdc, 1))).xyz;
    float shadowed=1.0;
'''+prepare.LOCAL_SOURCES[kind][1]+'''
    specular = AL_CalcSpecular(material,lightVec,-wsEyeVec)*Sat_NL_Att;
    lightinfoCondition(outData, lightColorOut * Sat_NL_Att * retroMul, Sat_NL_Att, specular, 0);
    return outData;
}
'''

class Prepare(unittest.TestCase):
    def test_exact_visual_detail_not_collision_or_lod_union(self):
        root=ET.fromstring('''<COLLADA><scene><instance_visual_scene url="#s"/></scene><library_visual_scenes><visual_scene id="s">
        <node id="base"><node id="shape_a100"><instance_geometry url="#low"/></node>
        <node id="shape_a200"><instance_geometry url="#high"/></node>
        <node id="Colmesh_shape"><instance_geometry url="#collision"/></node></node></visual_scene></library_visual_scenes></COLLADA>''')
        self.assertEqual(prepare.select_visual(root),'shape_a200')
        root.find('.//node[@id="shape_a100"]').set('id','other_a200')
        with self.assertRaises(ValueError):prepare.select_visual(root)
    def test_local_native_math_preserved_and_visibility_before_diffuse_and_specular(self):
        for kind in prepare.LOCAL_SOURCES:
            old=source(kind);new=prepare.generate_local(old,kind)
            for line in old.splitlines()[1:]:self.assertIn(line,new)
            self.assertLess(new.index('beamrtLocalShadowFactor'),new.index('float Sat_NL_Att'))
            self.assertIn('gbuffer.target0.w <= 0.0 && cb.lightMapParams.a >= 0.0',new)
            self.assertIn('cb.lightPosition, shadowed',new)
    def test_unknown_contract_does_not_patch_broadly(self):
        for kind in prepare.LOCAL_SOURCES:
            for text in (source(kind)*2,source(kind).replace('cb.screenToWorld','differentMatrix'),
                         source(kind)+'\nTexture2D existing:register(t14);'):
                with self.assertRaises(ValueError):prepare.generate_local(text,kind)
    def test_line_primitive_skip_is_opt_in_and_does_not_skip_unsupported_surface(self):
        import beamrt_scene_align as align
        import beamrt_scene_import as mesh
        from test_scene_align import document
        root=document('<node id="selected"><instance_geometry url="#wall"/></node>')
        geometry=mesh.first(mesh.descendants(root,'geometry')[0],'mesh')
        ET.SubElement(geometry,'lines')
        with self.assertRaises(ValueError):align.extract_selected(root,'selected')
        faces,meta=align.extract_selected(root,'selected',allow_non_surface_lines=True)
        self.assertEqual(len(faces),2)
        self.assertEqual(meta['skipped']['non-surface lines'],1)
        ET.SubElement(geometry,'tristrips')
        with self.assertRaises(ValueError):align.extract_selected(root,'selected',allow_non_surface_lines=True)

if __name__=='__main__':unittest.main(verbosity=2)
