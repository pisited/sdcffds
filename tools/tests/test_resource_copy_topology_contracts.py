"""Bounded CPU copy-failure evidence guards; native fixtures test real copies.

These source checks never load a DLL or launch BeamNG. They do not certify
descriptor contents, resource leases, camera meaning, states, or GPU ordering.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ResourceCopyTopologyContracts(unittest.TestCase):
    def source(self, name):
        return (ROOT / "native/startup" / name).read_text()

    def test_fixed_numeric_storage_not_another_resource_owner(self):
        header = self.source("resource_copy_diagnostics.h")
        for guard in ("beamrtResourceCopyFailureABI=3", "sizeof(BeamRTResourceCopyFailure)==29728",
                      "sizeof(BeamRTResourceCopyLane)==400", "sizeof(BeamRTResourceCopyHeap)==56",
                      "heaps[beamrtResourceHeapLimit]", "lanes[beamrtResourceCopyLimit]",
                      "BeamRTResourceView source,previousDestination", "BeamRT_ResourcesCopyFailure"):
            self.assertIn(guard, header)
        for forbidden in ("std::vector", "ComPtr", "ID3D12Resource*", "HANDLE ", "void*"):
            self.assertNotIn(forbidden, header)
        code = self.source("resource_tracker.cpp")
        self.assertIn("BeamRTResourceCopyFailure pendingCopy{};", code)
        self.assertIn("auto& pending=c.pendingCopy;pending={}", code)
        self.assertNotIn("BeamRTResourceCopyFailure pending{};", code)

    def test_only_first_actual_copy_capacity_failure_freezes_topology(self):
        code = self.source("resource_tracker.cpp")
        freeze = code[code.index("static void freezeCopyFailure("):code.index("static void copied(")]
        for guard in ("c.copyFailure.present", "!beamrtResourceStorageCapacityKind(c.firstFailure.kind)",
                      "c.firstFailure.method!=c.method", "BeamRTResourceMethodCopySimple",
                      "BeamRTResourceMethodCopyRanges", "pending.firstFailure=c.firstFailure",
                      "pending.appliedLanes=failedLane", "pending.storageFailure=c.storageFailure", "c.copyFailure=pending"):
            self.assertIn(guard, freeze)
        self.assertNotIn("reap(", freeze)
        self.assertNotIn("currentStatus(", freeze)

    def test_phase_data_precedes_mutation_and_source_values_remain_snapshots(self):
        code = self.source("resource_tracker.cpp")
        copy = code[code.index("static void copied("):code.index("using CreateHeap=")]
        self.assertLess(copy.index("lane.source=values[i]"), copy.index("clear(c,dst[i],type)"))
        self.assertLess(copy.index("find(c,destination->life->id,destinationIndex,lane.previousDestination)"), copy.index("clear(c,dst[i],type)"))
        self.assertLess(copy.index("copyEntryHeaps(c,pending)"), copy.index("clear(c,dst[i],type)"))
        self.assertLess(copy.index("clear(c,dst[i],type)"), copy.index("copyClearedHeaps(c,pending)"))
        self.assertLess(copy.index("copyClearedHeaps(c,pending)"), copy.index("write(c,dst[i],type,values[i])"))
        self.assertIn("c.method==BeamRTResourceMethodCopyRanges && dz?1u:0u", copy)

    def test_wrong_size_refuses_and_query_remains_immutable_after_off(self):
        code = self.source("resource_tracker.cpp")
        query = code[code.index('extern "C" HRESULT WINAPI BeamRT_ResourcesCopyFailure('):
                     code.index('extern "C" HRESULT WINAPI BeamRT_ResourcesDiagnostics(')]
        self.assertIn("if(!out || bytes!=sizeof(*out))return E_INVALIDARG;*out={}", query)
        self.assertIn("std::lock_guard<std::mutex> g(c->mutex);*out=c->copyFailure", query)
        self.assertIn("return out->present?S_OK:S_FALSE", query)
        self.assertNotIn("readable(", query)
        self.assertNotIn("reap(", query)

    def test_validator_requires_matching_event_and_bounded_complete_plan(self):
        validator = self.source("resource_copy_validation.h")
        for guard in ("beamrtResourceCopyFailureExpected", "beamrtResourceFailureValid(failure,status,expectedProfile)",
                      "copy.profile!=expectedProfile", "copy.reservedProfile",
                      "beamrtResourceStorageFailureValid(copy.storageFailure,failure,status,expectedProfile)",
                      "copy.mode!=expectedMode", "copy.failedLane>=copy.laneCount",
                      "copy.appliedLanes!=copy.failedLane", "copy.laneCount>beamrtResourceCopyLimit",
                      "copy.heapCount>beamrtResourceHeapLimit", "std::memcmp(&copy.firstFailure,&failure",
                      "atFailure!=failure.views", "copy.lanes[i]", "lane.previousDestination",
                      "if(i>=copy.laneCount)", "if(i>=copy.heapCount)", "if(i>=rangeCount)",
                      "offset>UINT64_MAX-range.start", "destinationCpu[i]==sourceCpu[j]"):
            self.assertIn(guard, validator)
        self.assertNotIn("ID3D12Resource*", validator)

    def test_publication_does_not_join_a_future_failure_or_hold_bridge_lock(self):
        bridge = self.source("resource_handoff.cpp")
        publish = bridge[bridge.index("void BeamRT_ResourcePublishForBinding("):
                         bridge.index('extern "C" HRESULT WINAPI BeamRT_ResourceRecordRead(')]
        self.assertLess(publish.index("if(beamrtResourceCopyFailureExpected(observation->firstFailure))"),
                        publish.index("BeamRT_ResourcesCopyFailure("))
        self.assertLess(publish.index("BeamRT_ResourcesCopyFailure("), publish.index("AcquireSRWLockExclusive"))
        self.assertLess(publish.index("beamrtResourceCopyFailureValid("), publish.index("AcquireSRWLockExclusive"))
        self.assertIn("*observation,copyFailure", publish)

    def test_transport_changes_explicitly_but_existing_metadata_does_not(self):
        header = self.source("resource_handoff.h")
        for guard in ("beamrtResourceHandoffABI=7", "sizeof(BeamRTResourceStartReceipt)==392",
                      "sizeof(BeamRTResourceRecordReceipt)==32768", "sizeof(BeamRTResourceReply)==33160",
                      "BeamRTResourceCopyFailure copyFailure"):
            self.assertIn(guard, header)
        self.assertIn("sizeof(BeamRTResourceFailure)==96", self.source("resource_tracker.h"))
        self.assertIn("sizeof(BeamRTResourceStatus)==88", self.source("resource_tracker.h"))
        self.assertIn("sizeof(BeamRTResourceDrawObservation)==3000", self.source("resource_record.h"))

    def test_interned_directory_counts_are_joined_to_actual_failure_topology(self):
        validator = self.source("resource_copy_validation.h")
        for guard in ("if(h.failureViews)++occupiedHeaps",
                      "expectedProfile==beamrtResourceStorageInterned && copy.storageFailure.atFailure.heaps!=occupiedHeaps",
                      "const auto* destination=heap(copy,failed.destinationHeapId)",
                      "expectedProfile!=beamrtResourceStorageInterned || (destination",
                      "copy.storageFailure.attemptedHeaps==occupiedHeaps+(destination->failureViews?0u:1u)"):
            self.assertIn(guard, validator)
        self.assertLess(validator.index("copy.storageFailure.atFailure.heaps!=occupiedHeaps"), validator.index("copy.storageFailure.attemptedHeaps==occupiedHeaps"))

    def test_cpu_copy_controls_require_individually_valid_but_false_heap_joins(self):
        fixture = self.source("descriptor_view_store_fixture.cpp")
        section = fixture[fixture.index("void internedCopyEvidence(){"):fixture.index("} // namespace", fixture.index("void internedCopyEvidence(){"))]
        for guard in ("mutated->storageFailure.atFailure.heaps=1",
                      "mutated->storageFailure.atFailure.heaps=mutated->storageFailure.attemptedHeaps=3",
                      "mutated->storageFailure.attemptedHeaps=3",
                      "beamrtResourceStorageFailureValid(mutated->storageFailure,failure,status,profile)", "!valid(*mutated)",
                      "copy accepted false original occupied H with valid byte math",
                      "copy accepted H+1 demand for an already occupied destination",
                      "copy.storageFailure.atFailure.heaps=1;copy.storageFailure.attemptedHeaps=2",
                      "mutated->storageFailure.attemptedHeaps=1",
                      "copy accepted unchanged H demand for an empty destination",
                      "mutated->heaps[0].aliveAtEntry=0", "mutated->heaps[2].aliveAtEntry=1", "need(valid(*mutated)"):
            self.assertIn(guard, section)

    def test_standalone_and_colinked_present_receipts_are_exercised(self):
        fixture = self.source("resource_fixture.cpp")
        for guard in ("--copy-prefix-pressure", "--copy-boundary-pressure", "--copy-simple-pressure", "--copy-explicit-pressure", "BeamRT_ResourcesCopyFailure",
                      "beamrtResourceCopyFailureValid", "immutableCopy", "malformed copy failure companion accepted"):
            self.assertIn(guard, fixture)
        harness = self.source("process_test.cpp")
        self.assertIn("resource-copy-pressure", harness)
        self.assertIn("receipt.copyFailure", harness)
        build = self.source("build_resource_tracker.ps1")
        self.assertIn("'copy-prefix','copy-boundary'", build)


if __name__ == "__main__":
    unittest.main()
