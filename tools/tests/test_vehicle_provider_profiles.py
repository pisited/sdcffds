"""Native-boundary tripwires using Lua-owned fake handles, NEVER the game DLL."""
import unittest
from lupa.luajit21 import LuaRuntime
from test_vehicle_pair_probe import FIXTURE,MODULES

EXTRA=r'''
optionalLookups=0;uvCalls=0;colorCalls=0
function forbidOptional(owner,allowUV0)
 local forbidden={}
 for _,stem in ipairs({'normals','tangents','uv1','uv2','vertColors'})do
  if not (allowUV0 and stem=='uv1')then
   for _,suffix in ipairs({'Count','Get'})do local key=stem..suffix;owner[key]=nil;forbidden[key]=true end
  end
 end
 setmetatable(owner,{__index=function(_,key)
  if forbidden[key]then optionalLookups=optionalLookups+1;error('Forbidden native stream lookup: '..key)end
 end})
end
function addPaddles()
 local p={meshName='ardente_paddles',verticesCount=479,indicesCount=1686,primitivesCount=1,
  vertColorsCount=479}
 function p:verticesGet(dst)for i=0,479*3-1 do dst[i]=(i%7)*.01 end;return true end
 function p:indicesGet(dst)for i=0,1686-1 do dst[i]=i%479 end;return true end
 function p:primitivesGet(dst)dst[0].startIndex=0;dst[0].indexCount=1686;dst[0].materialId=0;return true end
 function p:vertColorsGet()colorCalls=colorCalls+1;error('Simulated native crash getter MUST NOT run')end
 meshes[41].propmeshesCount=1;meshes[41].prop=p;return p
end
'''


class VehicleProviderProfiles(unittest.TestCase):
    def runtime(self,abi=None):
        lua=LuaRuntime(unpack_returned_tuples=True);lua.execute(FIXTURE);lua.execute(EXTRA)
        if abi:lua.execute("require('ffi').cdef[["+abi+']]' )
        provider=lua.execute((MODULES/'providers/vehicleProvider.lua').read_text())
        lua.globals().provider=provider
        return lua,provider

    def capture(self,lua,provider,profile='geometry'):
        lua.execute('meshes[41].dataIsReady=true')
        return provider.capture(41,lua.globals().meshes[41],profile)

    def test_geometry_profile_does_not_even_lookup_optional_stream_counts_or_getters(self):
        lua,p=self.runtime();lua.execute('local prop=addPaddles();forbidOptional(meshes[41],false);forbidOptional(prop,false)')
        record,err=self.capture(lua,p)
        self.assertIsNone(err);self.assertEqual(record.captureProfile,'geometry')
        self.assertEqual(record.propmeshes[1].meshName,'ardente_paddles')
        self.assertEqual(record.propmeshes[1].counts.vertices,479)
        self.assertEqual(record.propmeshes[1].primitives[1].indexCount,1686)
        self.assertEqual(lua.globals().optionalLookups,0)
        self.assertEqual(lua.globals().requests,0);self.assertEqual(lua.globals().freed,0)
        self.assertIsNone(record.mesh);self.assertFalse(record.nativeHandleRetained)
        for name in ('normals','tangents','uv1','uv2','vertexColors'):
            self.assertIsNone(record.buffers[name]);self.assertEqual(record.counts[name],0)

    def test_positive_color_count_and_crashing_color_getter_never_called(self):
        lua,p=self.runtime();lua.execute('addPaddles()')
        record,err=self.capture(lua,p)
        self.assertIsNone(err);self.assertIsNotNone(record)
        self.assertEqual(lua.globals().colorCalls,0)
        self.assertFalse(record.vertexColorsCaptured)
        self.assertEqual(record.propmeshes[1].counts.vertexColors,0)

    def test_glass_requests_shared_uv0_only_never_prop_uvs_or_other_optional_streams(self):
        lua,p=self.runtime();lua.execute('''
        local prop=addPaddles();forbidOptional(prop,false)
        meshes[41].uv1Count=3
        meshes[41].uv1Get=function(_,dst)uvCalls=uvCalls+1;for i=0,5 do dst[i]=i*.1 end;return true end
        forbidOptional(meshes[41],true)
        ''')
        record,err=self.capture(lua,p,'glass')
        self.assertIsNone(err);self.assertEqual(record.counts.uv1,3)
        self.assertIsNotNone(record.buffers.uv1)
        self.assertEqual(record.propmeshes[1].captureProfile,'geometry')
        self.assertEqual(record.propmeshes[1].counts.uv1,0)
        self.assertEqual(lua.globals().uvCalls,1);self.assertEqual(lua.globals().optionalLookups,0)

    def test_no_implicit_requests_and_unsupported_profiles_fail_before_ffi_allocation(self):
        lua,p=self.runtime()
        record,err=p.capture(41);self.assertIsNone(record);self.assertIn('caller-owned',err)
        ok,err=p.rebuild(lua.table_from({'vehicleId':41}));self.assertFalse(ok)
        for profile in ('full','colors','normals',lua.table_from({'colors':True})):
            record,err=p.capture(41,lua.globals().meshes[41],profile)
            self.assertIsNone(record);self.assertIn('disabled',err)
        self.assertEqual(lua.globals().requests,0);self.assertEqual(lua.globals().freed,0)
        self.assertEqual(lua.globals().allocations,0)

    def test_unready_and_failed_calls_never_free_caller_or_cache_partial_data(self):
        for value in ('false','0','nil','2'):
            lua,p=self.runtime();lua.execute('meshes[41].dataIsReady='+value)
            record,err=p.capture(41,lua.globals().meshes[41]);self.assertIsNone(record)
            self.assertEqual(lua.globals().allocations,0);self.assertEqual(lua.globals().freed,0)
        for mutation in ('meshes[41].verticesGet=function()return false end',
                         'meshes[41].verticesGet=function()return nil end',
                         'meshes[41].indicesGet=function()error("getter failure")end',
                         'meshes[41].primitiveCount=6','meshes[41].verticesCount=3.5'):
            lua,p=self.runtime();lua.execute(mutation)
            record,err=self.capture(lua,p);self.assertIsNone(record);self.assertIsNotNone(err)
            self.assertIsNone(p.get(41));self.assertEqual(lua.globals().freed,0)

    def test_primitive_abi_rejected_before_any_buffer_read_or_allocation(self):
        for abi in ('typedef struct gpuPrimitive_t {double startIndex; uint32_t indexCount; uint32_t materialId;} gpuPrimitive_t;',
                    'typedef struct gpuPrimitive_t {uint8_t wrong[12];} gpuPrimitive_t;'):
            lua,p=self.runtime(abi);record,err=self.capture(lua,p)
            self.assertIsNone(record);self.assertIn('ABI',err)
            self.assertEqual(lua.globals().allocations,0);self.assertEqual(lua.globals().freed,0)

    def test_cache_owns_only_cpu_copies_and_never_frees_native_handle(self):
        lua,p=self.runtime();record,err=self.capture(lua,p)
        self.assertIsNone(err)
        before=lua.globals().allocations
        duplicate,err=self.capture(lua,p);self.assertIsNone(duplicate);self.assertIn('cached',err)
        self.assertEqual(lua.globals().allocations,before)
        lua.execute("cars[41].names[1]='changed';meshes[41].positions[1]=42")
        self.assertEqual(record.materialNames[1],'test_body')
        self.assertEqual(record.buffers.vertices[0],-1)
        p.invalidate(41)
        self.assertEqual(record.buffers.vertices[0],-1)
        new,err=self.capture(lua,p);self.assertIsNone(err)
        self.assertEqual(new.buffers.vertices[0],42)
        p.invalidate('mission ended');self.assertIsNone(p.get(41))
        self.assertEqual(lua.globals().freed,0)
        self.assertEqual(p.getStats().nativeHandlesOwned,0)

    def test_stage_observer_has_detached_labels_before_and_after_native_copies(self):
        lua,p=self.runtime();lua.execute('''
        addPaddles();meshes[41].dataIsReady=true;stages={}
        function observer(stage)
          for key,value in pairs(stage)do assert(type(value)=='string')end
          stages[#stages+1]=stage.scope..'/'..stage.operation..'/'..stage.boundary
        end
        ''')
        record,err=p.capture(41,lua.globals().meshes[41],'geometry',lua.globals().observer)
        self.assertIsNone(err);self.assertIsNotNone(record)
        stages=list(lua.globals().stages.values())
        for scope,getter in (('root','verticesGet'),('root','indicesGet'),
                             ('flexmeshes[0]:body','primitivesGet'),
                             ('propmeshes[0]:ardente_paddles','verticesGet'),
                             ('propmeshes[0]:ardente_paddles','indicesGet'),
                             ('propmeshes[0]:ardente_paddles','primitivesGet')):
            before=scope+'/'+getter+'/before';after=scope+'/'+getter+'/after'
            self.assertIn(before,stages);self.assertEqual(stages.index(after),stages.index(before)+1)
        self.assertEqual(lua.globals().colorCalls,0)

    def test_observer_error_prevents_next_native_call_and_partial_cache(self):
        lua,p=self.runtime();lua.execute('''
        meshes[41].dataIsReady=true;vertexCalls=0
        meshes[41].verticesGet=function()vertexCalls=vertexCalls+1;return true end
        function observer(stage)
          if stage.operation=='verticesGet' and stage.boundary=='before'then error('journal unavailable')end
        end
        ''')
        record,err=p.capture(41,lua.globals().meshes[41],'geometry',lua.globals().observer)
        self.assertIsNone(record);self.assertIn('journal unavailable',err)
        self.assertEqual(lua.globals().vertexCalls,0);self.assertIsNone(p.get(41))
        self.assertEqual(lua.globals().freed,0)

    def test_invalid_observer_rejected_before_native_calls(self):
        lua,p=self.runtime()
        record,err=p.capture(41,lua.globals().meshes[41],'geometry',lua.table())
        self.assertIsNone(record);self.assertIn('observer',err)
        self.assertEqual(lua.globals().allocations,0)


if __name__=='__main__':unittest.main()
