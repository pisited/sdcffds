"""Descriptor-scoped resource admission guards; Python never loads native DLLs.

Source checks complement both isolated and production co-linked GPU fixtures.
They are not BeamNG compatibility, resource-state, camera, or lighting proof.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


def body(source, marker):
    start = source.index("{", source.index(marker))
    depth, end = 1, start + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start + 1:end - 1]


class ResourceAdmissionContracts(unittest.TestCase):
    def source(self, name):
        return (ROOT / "native/startup" / name).read_text()

    def test_explicit_configuration_and_unchanged_legacy_start(self):
        header = self.source("resource_tracker.h")
        for guard in ("beamrtResourceConfigABI=1", "beamrtResourceAllAllocations=0",
                      "beamrtResourceDescriptorTextures=1", "sizeof(BeamRTResourceConfig)==16",
                      "struct BeamRTResourceConfig {uint32_t bytes,abi,mode,reserved;}",
                      "BeamRT_ResourcesStartConfigured"):
            self.assertIn(guard, header)
        code = self.source("resource_tracker.cpp")
        legacy = body(code, 'extern "C" HRESULT WINAPI BeamRT_ResourcesStart(')
        self.assertIn("return startResources(d,beamrtResourceAllAllocations)", legacy)
        configured = body(code, 'extern "C" HRESULT WINAPI BeamRT_ResourcesStartConfigured(')
        for guard in ("!config", "config->bytes!=sizeof(*config)", "config->abi!=beamrtResourceConfigABI",
                      "config->reserved", "config->mode>beamrtResourceDescriptorTextures"):
            self.assertIn(guard, configured)
        self.assertLess(configured.index("return E_INVALIDARG"), configured.index("return startResources"))
        self.assertIn("c.mode=mode", body(code, "static HRESULT startResources("))

    def test_compact_storage_requires_versioned_immutable_descriptor_profile(self):
        code = self.source("resource_tracker.cpp")
        configured = body(code, 'extern "C" HRESULT WINAPI BeamRT_ResourcesStartConfigured(')
        self.assertIn("return startResources(d,config->mode)", configured)
        self.assertNotIn("config->profile", configured)
        profiled = body(code, 'extern "C" HRESULT WINAPI BeamRT_ResourcesStartProfiled(')
        for guard in ("config->bytes!=sizeof(*config)", "config->abi!=beamrtResourceProfileConfigABI",
                      "config->reserved[0]", "config->reserved[1]", "config->mode>beamrtResourceDescriptorTextures",
                      "config->profile>beamrtResourceStorageCompact",
                      "config->profile==beamrtResourceStorageCompact && config->mode!=beamrtResourceDescriptorTextures",
                      "return startResources(d,config->mode,config->profile)"):
            self.assertIn(guard, profiled)
        self.assertLess(profiled.index("return E_INVALIDARG"), profiled.index("return startResources"))
        start = body(code, "static HRESULT startResources(")
        self.assertLess(start.index("Context(profile)"), start.index("InterlockedExchangePointer(&published,resident)"))
        host = self.source("launcher.cpp")
        for guard in ("resourceProfile=beamrtResourceStorageLegacy", "--resource-compact-storage",
                      "out.resources && out.resourceMode==beamrtResourceDescriptorTextures && !out.resourceProbeBytes",
                      "legacy validator silently accepted compact startup", "legacy validator silently accepted compact status/failure ABI"):
            self.assertIn(guard, host)

    def test_interned_storage_has_a_separate_config_abi_and_no_implicit_selection(self):
        code = self.source("resource_tracker.cpp")
        interned = body(code, 'extern "C" HRESULT WINAPI BeamRT_ResourcesStartInterned(')
        for guard in ("config->bytes!=sizeof(*config)", "config->abi!=beamrtResourceInternedConfigABI",
                      "config->reserved[0]", "config->reserved[1]", "config->mode!=beamrtResourceDescriptorTextures",
                      "config->profile!=beamrtResourceStorageInterned", "return startResources(d,config->mode,config->profile)"):
            self.assertIn(guard, interned)
        self.assertLess(interned.index("return E_INVALIDARG"), interned.index("return startResources"))
        profile = self.source("resource_profile.h")
        self.assertIn("beamrtResourceInternedConfigABI=3", profile)
        self.assertIn("beamrtResourceProfileConfigABI=2", profile)
        host = self.source("launcher.cpp")
        for guard in ("--resource-interned-storage", 'seen[L"--resource-compact-storage"] && seen[L"--resource-interned-storage"]',
                      "out.resourceProfile!=beamrtResourceStorageInterned || (out.resources && out.resourceMode==beamrtResourceDescriptorTextures && !out.resourceProbeBytes)",
                      "legacy validator silently accepted interned zero-view startup", "compact validator silently accepted interned zero-view startup",
                      "malformed interned cold-empty/failure sample accepted", "invalid.profile=beamrtResourceStorageInterned+1"):
            self.assertIn(guard, host)
        fixture = self.source("resource_fixture.cpp")
        for guard in ("static int profiledFixture(", "BeamRT_ResourcesStartProfiled(device,&old)==E_INVALIDARG",
                      "BeamRT_ResourcesStartProfiled(device,&selected)==E_INVALIDARG", "BeamRT_ResourcesStartInterned(device,config)"):
            self.assertIn(guard, fixture)

    def test_interned_native_cases_join_physical_metrics_draw_and_off(self):
        fixture = self.source("binding_startup_fixture.cpp")
        for guard in ("observed.storage.locations==2000 && observed.storage.payloads==7 && observed.storage.usedBytes==29632",
                      "observed.storage.directoryBytes==512 && observed.storage.locationBytes==14",
                      "observed.storage.heaps==2 && observed.storage.heapLimit==32",
                      "e.attemptedHeaps==3 && e.requiredBytes==s.usedBytes+14+(payloadPressure?160u:0u)",
                      "payloadPressure?257u:47118u", "after.storage.usedBytes==1730 && after.storage.heaps==2",
                      "interned pressure falsely accepted metadata", "interned byte-capacity copy topology mismatch"):
            self.assertIn(guard, fixture)
        harness = self.source("process_test.cpp")
        for name in ("resource-interned", "resource-interned-payloads", "resource-interned-bytes"):
            self.assertIn(name+"-hardware", harness)
            self.assertIn(name+"-warp", harness)
        self.assertIn("interned.resourceDescriptorsOnly=true;interned.resourceInternedStorage=true", harness)
        self.assertIn("resourcesWarpOnly?19:31", harness)
        workflow = (ROOT / ".github/workflows/beamrt-native-worker.yml").read_text()
        self.assertIn("./native/startup/build_resource_tracker.ps1 -RunTest -RunCompactTests -RunInternedTests -Warp", workflow)

    def test_compact_fixture_covers_fanout_and_three_independent_limits(self):
        fixture = self.source("binding_startup_fixture.cpp")
        for guard in ("observed.storage.locations==307 && observed.storage.payloads==7 && observed.storage.usedBytes==8488",
                      'resourceMode==L"compact-locations"?1025u:resourceMode==L"compact-payloads"?257u:47128u',
                      "after.storage.locations==7 && after.storage.payloads==7 && after.storage.usedBytes==1288",
                      "compact draw receipt changed selected profile metrics or first failure",
                      "compact capacity receipt falsely accepted metadata"):
            self.assertIn(guard, fixture)
        harness = self.source("process_test.cpp")
        for name in ("resource-compact", "resource-compact-locations", "resource-compact-payloads", "resource-compact-bytes"):
            self.assertIn(name+"-hardware", harness)
            self.assertIn(name+"-warp", harness)
        self.assertIn("compact.resourceDescriptorsOnly=true;compact.resourceCompactStorage=true", harness)

    def test_creation_filter_does_not_skip_original_forwarding_or_overlap_accounting(self):
        code = self.source("resource_tracker.cpp")
        creation = body(code, "static void createdResource(")
        self.assertLess(creation.index("if(c.mode==beamrtResourceDescriptorTextures)return"),
                        creation.index("track(c,r.Get())"))
        self.assertIn("observe(call,", creation)
        for function, kind in (("committed", "Committed"), ("placed", "Placed"), ("reserved", "Reserved")):
            allocation = body(code, f"static HRESULT STDMETHODCALLTYPE {function}(")
            self.assertIn(f"Call call(d,BeamRTResourceMethod{kind})", allocation)
            self.assertLess(allocation.index(f"original<{kind}>("), allocation.index("createdResource(call,result,out)"))
            self.assertIn("LastError e{GetLastError()}", allocation)
            self.assertIn("return result", allocation)
        call = body(code, "struct Call {")
        self.assertIn("c->inFlight.fetch_add(1)", call)
        self.assertIn("fail(*c,BeamRTResourceFailureOverlap,0,active+1)", call)

    def test_supported_destination_and_view_are_checked_before_descriptor_admission(self):
        code = self.source("resource_tracker.cpp")
        for writer, heap_type, dimension in (("srvWritten", "CBV_SRV_UAV", "SRV"),
                                             ("rtvWritten", "RTV", "RTV")):
            write = body(code, f"static void {writer}(")
            mode = body(write, "if(c.mode==beamrtResourceDescriptorTextures)")
            self.assertIn(f"locate(c,dst.ptr,D3D12_DESCRIPTOR_HEAP_TYPE_{heap_type},index)", mode)
            self.assertIn("!child(c,resource)", mode)
            self.assertNotIn("track(", mode)
            self.assertLess(write.index("supportedTexture(resourceDesc)"), write.index("if(!o)o=track(c,resource)"))
            self.assertLess(write.index(f"desc->ViewDimension!=D3D12_{dimension}_DIMENSION_TEXTURE2D"),
                            write.index("if(!o)o=track(c,resource)"))
            self.assertIn("clear(c,dst.ptr,", write)
            self.assertIn("value.resourceId=o->life->id;value.canonicalIdentity=o->identity", write)
        self.assertIn("SetPrivateDataInterface(guid,tag.Get())", code)
        self.assertIn("~LifeTag(){life->alive.store(false);}", code)

    def test_partial_buffer_index_never_invents_cbv_uniqueness(self):
        code = self.source("resource_tracker.cpp")
        helper = body(code, "static HRESULT bufferCandidate(")
        self.assertLess(helper.index("out={}"), helper.index("if(c.mode==beamrtResourceDescriptorTextures)"))
        self.assertLess(helper.index("return HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED)"), helper.index("const Object* match"))
        query = body(code, 'extern "C" HRESULT WINAPI BeamRT_ResourcesBufferCandidate(')
        self.assertLess(query.index("*out={}"), query.index("if(c->mode==beamrtResourceDescriptorTextures)"))
        self.assertLess(query.index("return E_INVALIDARG"), query.index("if(c->mode==beamrtResourceDescriptorTextures)"))
        self.assertIn("return HRESULT_FROM_WIN32(ERROR_NOT_SUPPORTED)", query)
        self.assertIn("if(match)return HRESULT_FROM_WIN32(ERROR_INVALID_DATA)", helper)
        self.assertIn("out.candidateOnly=1", helper)

    def test_startup_retains_more_than_capacity_irrelevant_allocations_before_gi(self):
        fixture = self.source("binding_startup_fixture.cpp")
        before = fixture[fixture.index("std::vector<ComPtr<ID3D12Resource>> irrelevantResources"):
                         fixture.index("render.begin();std::vector<ComPtr<ID3D12Resource>> textures")]
        for guard in ("if(descriptorScoped)", "i<beamrtResourceObjectLimit+1",
                      "irrelevantResources.push_back(resource(device.Get(),buffer(256)",
                      "irrelevantResources.push_back(resource(device.Get(),unused",
                      "!empty.status.liveResources", "!empty.status.pressure", "!empty.status.overlaps",
                      "beamrtResourceFailureValid(empty.firstFailure,empty.status,resources.profile)",
                      "irrelevantResources.size()>beamrtResourceObjectLimit"):
            self.assertIn(guard, before)
        self.assertNotIn("irrelevantResources.clear(", fixture)
        self.assertNotIn("irrelevantResources.resize(", fixture)
        for forbidden in ("BeamRT_ResourcesStart(", "BeamRT_ResourcesStartConfigured("):
            self.assertNotIn(forbidden, fixture)

    def test_startup_has_exact_seven_admissions_and_no_buffer_metadata(self):
        fixture = self.source("binding_startup_fixture.cpp")
        for guard in ("observed.status.liveResources==7 && observed.status.views==7",
                      "descriptor startup did not admit exactly six inputs and one output",
                      "constants->GetGPUVirtualAddress(),readback->GetGPUVirtualAddress(),irrelevantResources[0]->GetGPUVirtualAddress()",
                      "FAILED(resourceCandidate(address,16,&candidate,sizeof(candidate)))",
                      "!std::memcmp(&candidate,&zero,sizeof(candidate))",
                      "!o.cbvProbeBytes && o.cbvResult==S_FALSE", "!std::memcmp(&o.cbv,&zero,sizeof(zero))",
                      "resources.inputIdentities[i]=canonical(textures[i].Get())",
                      "resources.outputIdentity=canonical(target.Get())"):
            self.assertIn(guard, fixture)
        harness = self.source("process_test.cpp")
        for guard in ("o.status.liveResources==7 && o.status.views==7", "o.srvResults[i]==S_OK",
                      "o.srvs[i].canonicalIdentity==resources.inputIdentities[i]",
                      "o.rtvs[0].canonicalIdentity==resources.outputIdentity",
                      "!std::memcmp(&o.cbv,&zero,sizeof(zero))"):
            self.assertIn(guard, harness)

    def test_relevant_pressure_refuses_at_admission_not_native_allocation(self):
        fixture = self.source("binding_startup_fixture.cpp")
        pressure = body(fixture, 'if(resourceMode==L"descriptor-pressure")')
        for guard in ("while(liveCount<beamrtResourceObjectLimit)",
                      "descriptorPressure.push_back(resource(", "observed.status.liveResources==liveCount",
                      "descriptor allocation admitted before its SRV",
                      "descriptor capacity refused native allocation rather than admission",
                      "descriptorFailure.kind==BeamRTResourceFailureObjectCapacity",
                      "descriptorFailure.method==BeamRTResourceMethodCreateSRV",
                      "descriptorFailure.capacityLimit==beamrtResourceObjectLimit",
                      "descriptorFailure.attemptedCount==beamrtResourceObjectLimit+1",
                      "descriptorFailure.liveResources==beamrtResourceObjectLimit"):
            self.assertIn(guard, pressure)
        self.assertEqual(pressure.count("device->CreateShaderResourceView(descriptorPressure.back().Get()"), 2)
        self.assertNotIn("descriptorPressure.clear(", fixture)
        for guard in ("descriptor capacity receipt lost first failure", "resource OFF changed descriptor capacity first failure",
                      "resources.after.restoredSlots==10", "resource OFF changed GPU pixel"):
            self.assertIn(guard, fixture)
        self.assertEqual(fixture.count("footprint.Offset)-23)<.00001f"), 2)

    def test_production_hardware_warp_modes_and_echo_are_wired(self):
        harness = self.source("process_test.cpp")
        for guard in ("resource-descriptors-hardware", "resource-descriptors-warp",
                      "resource-descriptor-pressure-hardware", "resource-descriptor-pressure-warp",
                      'descriptor.bindingMode=L"resource-descriptors"', 'descriptor.bindingMode=L"resource-descriptor-pressure"',
                      "descriptor.resourceDescriptorsOnly=true;descriptor.resourceProbeBytes=0;descriptor.warp=warp",
                      'args.insert(args.end()-1,L"--resource-descriptors-only")',
                      "resources.mode==expectedMode", "beamrtResourceStartReceiptValid(start,result.processId,result.status.attachThread,expectedMode,expectedProfile)", "receipt.mode==expectedMode",
                      "!resources.reserved && !resources.reserved2", "!resources.reservedProfile", "!receipt.reserved",
                      "o.firstFailure.method==BeamRTResourceMethodCreateSRV", "resourcesWarpOnly?19:31"):
            self.assertIn(guard, harness)
        self.assertIn("parent resource receipt differs from actual fixture", harness)
        self.assertIn("resources.pixelAfterOff==1", harness)

    def test_mode_transport_is_versioned_not_hidden_in_reserved_metadata(self):
        header = self.source("resource_handoff.h")
        for guard in ("beamrtResourceHandoffABI=7", "sizeof(BeamRTResourcePayload)==56",
                      "sizeof(BeamRTResourceStartReceipt)==392", "sizeof(BeamRTResourceRecordReceipt)==32768",
                      "sizeof(BeamRTResourceReply)==33160", "uint32_t cbvProbeBytes,mode",
                      "p->mode<=beamrtResourceDescriptorTextures", "p->mode!=beamrtResourceDescriptorTextures || !p->cbvProbeBytes",
                      "r.mode==expectedMode && !r.reserved"):
            self.assertIn(guard, header)
        record = self.source("resource_record.h")
        self.assertIn("beamrtResourceDrawABI=5", record)
        self.assertIn("sizeof(BeamRTResourceDrawObservation)==3000", record)
        self.assertIn("!s.reserved && !s.reserved2", header)

    def test_legacy_capacity_and_buffer_alias_regressions_are_retained(self):
        fixture = self.source("binding_startup_fixture.cpp")
        legacy = body(fixture, 'if(resourceMode==L"objects")')
        for guard in ("observed.status.liveResources==9", "if(liveCount==60)crossedCorruptSlot=true",
                      "objectFailure.method==BeamRTResourceMethodCommitted", "objectFailure.attemptedCount==beamrtResourceObjectLimit+1"):
            self.assertIn(guard, legacy)
        standalone = self.source("resource_fixture.cpp")
        for guard in ("candidate.offset==256", "known aliased address not refused", "retired buffer candidate remained available"):
            self.assertIn(guard, standalone)
        self.assertIn("--descriptor-mode", standalone)
        self.assertIn("@('heap','resource','view','draw','overlap','copy','copy-prefix','copy-boundary','copy-simple','copy-explicit')", self.source("build_resource_tracker.ps1"))


if __name__ == "__main__":
    unittest.main()
