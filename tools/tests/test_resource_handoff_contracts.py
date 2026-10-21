"""Default-off startup resource receipts and CPU interval guards, no native launch."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]


class ResourceHandoffContracts(unittest.TestCase):
    def source(self, name):
        return (ROOT / "native/startup" / name).read_text()

    def test_separate_payload_default_off_and_explicit_probe(self):
        host = self.source("launcher.cpp")
        for guard in ("bool resources=false", "resourceProbeBytes=0", "--observe-gi-resources",
                      "resource observation requires explicit binding observation",
                      "resource probe requires explicit resource observation",
                      "resource CBV probe must be 1-65536", "options.resources?14:options.bindings?12",
                      "beamrtResourceGuid"):
            self.assertIn(guard, host)
        bridge = self.source("resource_handoff.cpp")
        self.assertIn("if(!p)return S_FALSE", bridge)
        self.assertIn("beamrtResourcePayloadValid", bridge)
        self.assertNotIn("ResourcesStart", self.source("bootstrap.cpp"))

    def test_unchanged_old_transport_new_output_preflight(self):
        old = self.source("binding_handoff.h")
        for guard in ("beamrtBindingHandoffABI=2", "==1144", "==1184", "==912"):
            self.assertIn(guard, old)
        header = self.source("resource_handoff.h")
        for guard in ("==56", "==392", "==32768", "==33160", "beamrtResourceHandoffABI=7", "p->outputMapping!=p->startEvent",
                      "p->cbvProbeBytes<=65536", "p->processId==pid", "p->initialThread==thread"):
            self.assertIn(guard, header)
        host = self.source("launcher.cpp")
        for guard in ('L".resources.bin"', 'L".resources-start.bin"',
                      "thread evidence output already exists", "CREATE_NEW"):
            self.assertIn(guard, host)

    def test_native_draw_bracket_not_lock_across_native_execution(self):
        code = self.source("gi_bindings.cpp")
        for guard in ("ResourceDrawScope scope", "BeamRT_ResourcesBeginDraw", "BeamRT_ResourcesCancelDraw",
                      "SetLastError(incoming)", "BeamRT_ResourcesFinishDraw", "BeamRT_ResourceProbeBytes()"):
            self.assertIn(guard, code)
        record = self.source("resource_tracker.cpp")
        for guard in ("beamrtResourceDrawLimit", "held.ticket==token.ticket", "held.callbacks==token.callbacks",
                      "token.thread!=GetCurrentThreadId()", "value.callbacks!=c->status.callbacks",
                      "c->draws[value.slot]={}", "out->intervalAccepted=1"):
            self.assertIn(guard, record)
        for forbidden in ("CreateThread", "ExecuteCommandLists", "CreateCommandQueue", "->Map(", "BeamRT_GIRecord"):
            self.assertNotIn(forbidden, record)

    def test_publish_matches_first_binding_before_its_event(self):
        bridge = self.source("binding_handoff.cpp")
        self.assertLess(bridge.index("BeamRT_ResourcePublishForBinding(frame,thread,resources)"),
                        bridge.index("recorded=true;SetEvent(recordEvent)"))
        resource = self.source("resource_handoff.cpp")
        for guard in ("!resourceRecorded", "beamrtResourceObservationValid", "frame.serial,selectedMode,0,selectedProfile,0,*observation,copyFailure", "FILE_MAP_WRITE"):
            self.assertIn(guard, resource)
        for forbidden in ("LoadLibrary", "CreateThread", "BeamRT_CaptureStart", "BeamRT_GIRecord", "ExecuteCommandLists"):
            self.assertNotIn(forbidden, resource)

    def test_descriptor_mode_is_explicit_echoed_and_cannot_probe_cbv(self):
        host = self.source("launcher.cpp")
        for guard in ("resourceMode=beamrtResourceAllAllocations", '--resource-descriptors-only',
                      "resource descriptors-only mode requires explicit resource observation",
                      "descriptor-only resource observation does not support a CBV probe",
                      "options.resourceProbeBytes,options.resourceMode", "receipt.mode!=options.resourceMode || receipt.reserved",
                      "beamrtResourceStartReceiptValid(resourceReady,process.dwProcessId,process.dwThreadId,options.resourceMode,options.resourceProfile)",
                      "descriptor-only CBV probe payload accepted", "mismatched startup resource mode accepted"):
            self.assertIn(guard, host)
        header = self.source("resource_handoff.h")
        for guard in ("uint32_t cbvProbeBytes,mode", "p->mode<=beamrtResourceDescriptorTextures",
                      "p->mode!=beamrtResourceDescriptorTextures || !p->cbvProbeBytes",
                      "uint32_t mode,reserved,profile,reserved2;",
                      "BeamRTResourceStatus status;BeamRTResourceFailure firstFailure;BeamRTResourceStorageSnapshot storage;BeamRTResourceStorageFailure storageFailure;",
                      "expectedMode<=beamrtResourceDescriptorTextures", "r.mode==expectedMode && !r.reserved"):
            self.assertIn(guard, header)
        bridge = self.source("resource_handoff.cpp")
        for guard in ("resourceMode=p->mode", "resourceProfile=p->profile",
                      "const bool interned=p->profile==beamrtResourceStorageInterned",
                      "BeamRTResourceProfileConfig config{sizeof(config),interned?beamrtResourceInternedConfigABI:beamrtResourceProfileConfigABI,p->mode,p->profile,{0,0}}",
                      "interned?BeamRT_ResourcesStartInterned(device,&config):BeamRT_ResourcesStartProfiled(device,&config)",
                      "BeamRT_ResourcesStartProfiled(device,&config)", "result,resourceMode,0,resourceProfile,0",
                      "selectedMode==beamrtResourceDescriptorTextures && observation->cbvProbeBytes"):
            self.assertIn(guard, bridge)
        self.assertNotIn("BeamRT_ResourcesStart(device)", bridge)

    def test_copy_companion_is_appended_and_joins_only_the_original_cause(self):
        header = self.source("resource_handoff.h")
        self.assertIn("BeamRTResourceDrawObservation observation;BeamRTResourceCopyFailure copyFailure;", header)
        self.assertIn('#include "resource_copy_validation.h"', header)
        self.assertIn('#include "resource_view_validation.h"', header)
        self.assertNotIn("inline bool beamrtResourceViewValid(", header)
        bridge = self.source("resource_handoff.cpp").split("void BeamRT_ResourcePublishForBinding(", 1)[1].split('extern "C" HRESULT WINAPI BeamRT_ResourceRecordRead', 1)[0]
        for guard in ("copyFailure.bytes=sizeof(copyFailure)", "copyFailure.abi=beamrtResourceCopyFailureABI",
                      "if(beamrtResourceCopyFailureExpected(observation->firstFailure))",
                      "BeamRT_ResourcesCopyFailure(&copyFailure,sizeof(copyFailure))", "if(queried!=S_OK)return",
                      "beamrtResourceCopyFailureValid(copyFailure,observation->firstFailure,observation->status,selectedMode,selectedProfile)",
                      "std::memcmp(&copyFailure.storageFailure,&observation->storageFailure,sizeof(copyFailure.storageFailure))"):
            self.assertIn(guard, bridge)
        self.assertLess(bridge.index("if(beamrtResourceCopyFailureExpected"), bridge.index("BeamRT_ResourcesCopyFailure("))
        self.assertLess(bridge.index("BeamRT_ResourcesCopyFailure("), bridge.index("AcquireSRWLockExclusive(&resourceBridgeLock)"))
        self.assertLess(bridge.index("beamrtResourceCopyFailureValid("), bridge.index("AcquireSRWLockExclusive(&resourceBridgeLock)"))
        host = self.source("launcher.cpp")
        for guard in ("beamrtResourceCopyFailureValid(receipt.copyFailure,observation.firstFailure,observation.status,receipt.mode,options.resourceProfile)",
                      "malformed empty copy companion accepted", "copy-capacity first cause accepted without its companion",
                      "no matching draw means no later companion artifact"):
            self.assertIn(guard, host)
        harness = self.source("process_test.cpp")
        for guard in ("resource-copy-pressure-warp", "resource-copy-pressure-hardware", "copy.present==1",
                      "co-linked copy-capacity companion absent or misattributed", "resourcesWarpOnly?19:31"):
            self.assertIn(guard, harness)

    def test_fail_closed_receipt_shape_and_proof_flags(self):
        header = self.source("resource_handoff.h")
        for guard in ("o.snapshotSerial!=s.serial", "o.generation!=s.generation", "o.commandId!=s.commandId",
                      "o.callbacksBegin>o.callbacksEnd", "o.callbacksBegin!=o.callbacksEnd",
                      "o.status.callbacks!=o.callbacksEnd", "o.rtvCount!=s.renderTargetCount",
                      "o.outputThread!=thread", "o.outputCallbacks!=o.callbacksBegin", "o.outputCheckpointValid",
                      "c.candidateOnly!=1", "c.address!=s.cbv", "o.cbvProbeBytes>c.availableBytes",
                      "o.descriptorProvenanceVerified", "o.cbvContentsVerified", "o.cameraVerified",
                      "o.gpuOrderingVerified", "o.lightingConsumed", "beamrtResourceZero"):
            self.assertIn(guard, header)

    def test_all_copy_consumers_join_the_same_immutable_storage_failure(self):
        bridge = self.source("resource_handoff.cpp")
        self.assertIn("beamrtResourceCopyFailureExpected(observation->firstFailure)", bridge)
        self.assertIn("std::memcmp(&copyFailure.storageFailure,&observation->storageFailure,sizeof(copyFailure.storageFailure))", bridge)
        host = self.source("launcher.cpp")
        self.assertIn("beamrtResourceCopyFailureExpected(observation.firstFailure)", host)
        self.assertIn("std::memcmp(&receipt.copyFailure.storageFailure,&observation.storageFailure,sizeof(observation.storageFailure))", host)
        harness = self.source("process_test.cpp")
        self.assertIn("!beamrtResourceCopyFailureExpected(receipt.observation.firstFailure)", harness)
        self.assertIn("!std::memcmp(&receipt.copyFailure.storageFailure,&receipt.observation.storageFailure,sizeof(receipt.observation.storageFailure))", harness)

    def test_connected_fixture_has_no_manual_start_and_compares_gpu_off(self):
        fixture = self.source("binding_startup_fixture.cpp")
        for forbidden in ("BeamRT_ResourcesStart(", "BeamRT_BindingsStart("):
            self.assertNotIn(forbidden, fixture)
        for guard in ("resources.inputIdentities[i]", "resources.pixelAfterOff", "resource OFF changed GPU pixel",
                      "resourceMode==L\"partial\"", "resourceMode==L\"pressure\"",
                      "render.uploads.push_back(upload);render.submit();textures[0]=std::move(partial)"):
            self.assertIn(guard, fixture)
        harness = self.source("process_test.cpp")
        for guard in ("resource-startup-hardware", "resource-startup-warp", "resource-probe-default-off",
                      "resource-partial-view", "resource-capacity-refusal", "resource-without-draw",
                      "resource-default-off", "resource-output-preserved", "parent resource receipt differs",
                      "resource-output-reused-after-binding", "RTV reuse after binding falsely accepted",
                      "resource OFF changed GPU output", "all private jobs drained"):
            self.assertIn(guard, harness)

    def test_standalone_interval_negatives_and_four_capacities(self):
        fixture = self.source("resource_fixture.cpp")
        for guard in ("consumed draw token replay accepted", "forged interval accepted",
                      "foreign caller consumed interval", "resource write during interval accepted",
                      "draw token capacity bypassed", "BeamRT_ResourcesCancelDraw"):
            self.assertIn(guard, fixture)
        self.assertIn("@('heap','resource','view','draw','overlap','copy','copy-prefix','copy-boundary','copy-simple','copy-explicit')", self.source("build_resource_tracker.ps1"))

    def test_fresh_startup_artifacts_preserve_frozen_previous_builds(self):
        build = self.source("build.ps1")
        for guard in ("$FreshArtifacts", "Guid]::NewGuid", "resource_handoff.cpp", "resource_tracker.cpp",
                      "resource_slots.c", "/DBEAMRT_RESOURCE_EMBEDDED", "RunResourceStartupTests", "--resources", "--resources-warp"):
            self.assertIn(guard, build)
        self.assertNotIn("BeamNG.drive.x64.exe", build)


if __name__ == "__main__":
    unittest.main()
