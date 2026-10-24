"""Source guards for descriptor storage and its explicitly profiled integration.

These checks neither build/load a native DLL nor demonstrate GPU or game access.
The executable fixture checks raw-value behavior and an independent reference.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
STARTUP = ROOT / "native/startup"


def body(source, marker):
    start = source.index("{", source.index(marker))
    depth, end = 1, start + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start + 1:end - 1]


class DescriptorViewStoreContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.header = (STARTUP / "descriptor_view_store.h").read_text()
        cls.fixture = (STARTUP / "descriptor_view_store_fixture.cpp").read_text()
        cls.build = (STARTUP / "build_descriptor_view_store.ps1").read_text()

    def test_compact_integration_requires_explicit_profile_not_new_gpu_capability(self):
        self.assertIn("Legacy remains the default; compact can", self.header)
        self.assertIn("only be selected by the versioned profiled API/transport", self.header)
        self.assertIn("explicit caller-supplied observation", self.header)
        self.assertIn("not a resource lease, lifetime detector", self.fixture)
        self.assertIn("no observer, game or GPU proof", self.fixture)
        tracker = (STARTUP / "resource_tracker.cpp").read_text()
        self.assertIn('#include "resource_view_storage.h"', tracker)
        self.assertIn("uint32_t profile=beamrtResourceStorageLegacy", tracker)
        self.assertIn("explicit Context(uint32_t selectedProfile):profile(selectedProfile),views(selectedProfile)", tracker)
        wrapper = (STARTUP / "resource_view_storage.h").read_text()
        self.assertIn("profile==beamrtResourceStorageLegacy)backend_.emplace<old::Store>(old::legacyLimits)", wrapper)
        self.assertIn("profile==beamrtResourceStorageCompact)backend_.emplace<old::Store>(old::compactLimits)", wrapper)
        for name in ("gi_bindings.cpp", "resource_handoff.h", "build.ps1"):
            self.assertNotIn('"descriptor_view_store.h"', (STARTUP / name).read_text())
        for forbidden in ("CreateDevice(", "LoadLibrary", "BeamRT_ResourcesStart(", "GetGPUVirtualAddress("):
            self.assertNotIn(forbidden, self.fixture)

    def test_fixed_arena_and_explicit_three_way_capacity(self):
        for guard in ("legacyLocationLimit=256,compactLocationLimit=1024", "compactLimits{compactLocationLimit,256}",
                      "keyBytes==152 && sizeof(Payload)==160 && sizeof(Location)==24", "arenaBytes==47104",
                      "std::array<uint8_t,arenaBytes> arena_", "sizeof(Store)<=arenaBytes+64",
                      "Cause::LocationCapacity", "Cause::PayloadCapacity", "Cause::ByteCapacity"):
            self.assertIn(guard, self.header)
        storage_code = re.sub(r"//[^\n]*|/\*.*?\*/", "", self.header, flags=re.S)
        for forbidden in ("std::vector", "malloc(", "new ", "ComPtr", "realloc("):
            self.assertNotIn(forbidden, storage_code)
        put = body(self.header, "Result put(")
        self.assertIn("required>arenaBytes", put)
        self.assertIn("locations_==limits_.locations", put)
        self.assertIn("fresh && payloads_==limits_.payloads", put)
        self.assertIn("attemptedPayloads", put)

    def test_full_exact_payload_key_excludes_only_location_fields(self):
        for guard in ("headBytes=offsetof(BeamRTResourceView,heapId)",
                      "middleBegin=offsetof(BeamRTResourceView,resourceId)",
                      "middleBytes=offsetof(BeamRTResourceView,revision)-middleBegin",
                      "tailBegin=offsetof(BeamRTResourceView,resource)",
                      "tailBytes=sizeof(BeamRTResourceView)-tailBegin"):
            self.assertIn(guard, self.header)
        encode = body(self.header, "inline Key encode(")
        decode = body(self.header, "inline void decode(")
        self.assertEqual(encode.count("std::memcpy("), 3)
        self.assertEqual(decode.count("std::memcpy("), 3)
        self.assertIn("view.heapId=location.heap;view.revision=location.revision", decode)
        put = body(self.header, "Result put(")
        self.assertIn("payload(i).key==key", put)
        self.assertNotIn("canonicalIdentity==", put)
        self.assertNotIn("resourceId==", put)

    def test_revision_normalization_clear_and_fail_closed_contracts(self):
        put = body(self.header, "Result put(")
        self.assertLess(put.index("view.heapId=heap"), put.index("beamrtResourceViewValid(view,view.kind)"))
        self.assertIn("view.revision<=lastRevision_", put)
        self.assertLess(put.index("detail::encode(view)"), put.index("eraseAt(old)"))
        self.assertLess(put.index("eraseAt(old)"), put.index("required=used()"))
        get = body(self.header, "Result get(")
        self.assertLess(get.index("out={}"), get.index("if(!healthy())"))
        self.assertIn("if(!heap)return Result::Invalid", get)
        self.assertNotIn("poison(", get)
        poison = body(self.header, "Result poison(")
        self.assertIn("if(healthy())failure_=", poison)
        self.assertIn("locations_,payloads_,used()", poison)
        for marker in ("Result erase(", "Result retireHeap(", "Result retireResource("):
            section = body(self.header, marker)
            self.assertIn("if(!healthy())return Result::Unhealthy", section)
            self.assertNotIn("lastRevision_=", section)

    def test_refcount_reclamation_repairs_every_moved_payload_location(self):
        erase = body(self.header, "void eraseAt(")
        for guard in ("--oldPayload.references", "if(oldPayload.references)", "payload(old.payload,payload(lastPayload))",
                      "j<locations_", "value.payload==lastPayload", "value.payload=old.payload", "--payloads_"):
            self.assertIn(guard, erase)
        retire = body(self.header, "Result retireResource(")
        self.assertIn("detail::resourceId(payload(location(i).payload).key)==resource", retire)
        self.assertNotIn("canonicalIdentity", retire)

    def test_fixture_preserves_legacy_and_demonstrates_conditional_sharing(self):
        legacy = body(self.fixture, "void legacyDistinct(")
        self.assertIn("i<256", legacy)
        self.assertIn("stats(store,256,256,47104)", legacy)
        fanout = body(self.fixture, "void compactFanout(")
        self.assertIn("i<1024", fanout)
        self.assertIn("stats(store,1024,1,24736)", fanout)
        self.assertIn("store.stats().usedBytes<=ds::arenaBytes", fanout)
        control = body(self.fixture, "void redundancyCapacityControl(")
        for guard in ("stats(store,256,256,47104)", "ds::Cause::ByteCapacity", "f.requiredBytes==47128",
                      "stats(store,256,255,46944)", "stats(store,257,255,46968)", "actual redundancy"):
            self.assertIn(guard, control)

    def test_fixture_checks_exact_full_bytes_and_padding_not_semantic_dedup(self):
        exact = body(self.fixture, "void exactPayloadBytes(")
        for guard in ("ResourceMinLODClamp=0.25f", "MostDetailedMip=1", "MipLevels=2", "defaultView=1", "changed.kind=2",
                      "MipSlice=1", "resource.Width=32", "offsetof(View,resource)+sizeof(D3D12_RESOURCE_DIMENSION)",
                      "negativeZero=0x80000000u", "changed.canonicalIdentity+=16", "changed.resourceId=2", "MipLevels=UINT_MAX",
                      "stats(store,15,15,2760)", "stats(store,16,15,2784)"):
            self.assertIn(guard, exact)
        self.assertIn("bytes(out)==expected", self.fixture)
        self.assertIn("all 152 shared bytes", exact)

    def test_fixture_snapshot_retirement_and_independent_capacity_failures(self):
        snapshot = body(self.fixture, "void snapshotRetirement(")
        for guard in ("oldImage", "source overwrite", "destination overwrite", "second shared C reference",
                      "same-address new numeric lifetime", "store.retireResource(3)", "store.retireHeap(5)", "stats(store,0,0,0)"):
            self.assertIn(guard, snapshot)
        capacities = body(self.fixture, "void boundedFailures(")
        for guard in ("ds::Limits{2,2}", "ds::Limits{4,1}", "ds::Limits{1,1}", "ds::Cause::LocationCapacity",
                      "ds::Cause::PayloadCapacity", "ds::Cause::ByteCapacity", "f.locations==1023", "f.requiredBytes==47136"):
            self.assertIn(guard, capacities)
        failure = body(self.fixture, "void poisoned(")
        self.assertIn("std::memcmp(&failure,&after,sizeof(failure))", failure)
        self.assertIn("ds::Result::Unhealthy", failure)
        self.assertIn("post-clear storage, not promise rollback", failure)

    def test_fixture_invalid_queries_and_monotonic_revisions(self):
        invalid = body(self.fixture, "void invalidQueriesAndMutations(")
        for guard in ("cleared(store,0,0,ds::Result::Invalid)", "cleared(store,1,0,ds::Result::NotFound)",
                      "which<14", "quiet_NaN()", "infinity()", "invalidLimits", "store.erase(0,0)",
                      "store.retireHeap(0)", "store.retireResource(0)", "which<4", "ds::Cause::Revision"):
            self.assertIn(guard, invalid)
        self.assertIn("beamrtResourceZero(out)", body(self.fixture, "void cleared("))

    def test_randomized_full_value_oracle_is_independent_and_then_exhausted(self):
        oracle = body(self.fixture, "Image payloadKey(")
        self.assertNotIn("detail::encode(", oracle)
        self.assertEqual(oracle.count("std::memset("), 2)
        self.assertIn("using Reference=std::map<Address,Image>", self.fixture)
        reference = body(self.fixture, "void checkReference(")
        self.assertIn("std::set<Image> distinct", reference)
        self.assertIn("locations*24+payloads*160", reference)
        random = body(self.fixture, "void randomizedReference(")
        for guard in ("iteration<5000", "++revision", "reference.erase(", "store.retireHeap(heap)",
                      "store.retireResource(resource)", "checkReference(store,reference)",
                      "stats(store,64,1,1696)", "post-randomized planned exhaustion"):
            self.assertIn(guard, random)

    def test_dead_diagnostic_reaping_cannot_recover_or_replace_failure(self):
        occupied = body(self.header, "uint32_t occupied(")
        self.assertIn("if(!heap)return locations_", occupied)
        for marker, invalid in (("Result reapDeadHeap(", "if(!heap)return Result::Invalid"),
                                ("Result reapDeadResource(", "if(!resource)return Result::Invalid")):
            reap = body(self.header, marker)
            self.assertIn(invalid, reap)
            self.assertIn("eraseAt(i)", reap)
            for forbidden in ("failure_=", "lastRevision_=", "poison(", "put(", "if(!healthy())"):
                self.assertNotIn(forbidden, reap)
        diagnostic = body(self.fixture, "void diagnosticReaping(")
        for guard in ("reapDeadHeap", "reapDeadResource", "occupied(", "Result::Unhealthy", "std::memcmp"):
            self.assertIn(guard, diagnostic)
        self.assertIn("diagnosticReaping()", body(self.fixture, "int main("))

    def test_dead_resource_id_is_reaped_before_registry_slot_overwrite(self):
        tracker = (STARTUP / "resource_tracker.cpp").read_text()
        track = body(tracker, "static Object* track(")
        self.assertLess(track.index("c.views.reapDeadResource(o.life->id)"), track.index("Object next"))
        self.assertLess(track.index("c.views.reapDeadResource(o.life->id)"), track.index("storeTag("))
        self.assertLess(track.index("c.views.reapDeadResource(o.life->id)"), track.index("o=std::move(next)"))
        reap = body(tracker, "static void reap(")
        self.assertIn("h.life && !live(h.life)", reap)
        self.assertIn("o.life && !live(o.life)", reap)
        self.assertNotIn("c.status.healthy=", reap)
        self.assertNotIn("c.firstFailure=", reap)

    def test_storage_refusals_keep_specific_limits_and_actual_demand_units(self):
        tracker = (STARTUP / "resource_tracker.cpp").read_text()
        find = body(tracker, "static bool find(")
        self.assertIn("if(result==viewStore::Result::NotFound)return false", find)
        self.assertIn("fail(c,BeamRTResourceFailureMetadataException)", find)
        write = body(tracker, "static void write(")
        for guard in ("held.cause==viewStore::Cause::LocationCapacity",
                      "pressure(c,BeamRTResourceFailureViewCapacity,beamrtResourceLocationLimit(c.profile),held.attemptedLocations)",
                      "pressure(c,BeamRTResourceFailureViewPayloadCapacity,beamrtResourceStoragePayloadLimit,held.attemptedPayloads)",
                      "pressure(c,BeamRTResourceFailureViewByteCapacity,beamrtResourceStorageByteLimit,held.requiredBytes)"):
            self.assertIn(guard, write)
        self.assertIn("fail(c,BeamRTResourceFailureMetadataException)", write)
        self.assertIn("beamrtResourceViewLimit==viewStore::legacyLocationLimit", tracker)
        self.assertIn("return c.views.occupied(heap)", body(tracker, "static uint32_t occupiedViews("))
        self.assertIn("f.views=c.views.occupied()", body(tracker, "static void fail("))
        self.assertIn("out.views=c.views.occupied()", body(tracker, "static BeamRTResourceStatus currentStatus("))
        self.assertIn("'descriptor_view_store.h'", (STARTUP / "build_resource_tracker.ps1").read_text())

    def test_profile_transport_is_versioned_while_legacy_layouts_and_caps_remain(self):
        header = (STARTUP / "resource_tracker.h").read_text()
        for symbol, limit in (("Heap", 32), ("Object", 128), ("View", 256), ("Copy", 64), ("Draw", 16)):
            self.assertRegex(header, rf"beamrtResource{symbol}Limit\s*=\s*{limit}\b")
        for typename, size in (("BeamRTResourceView", 168), ("BeamRTResourceStatus", 88), ("BeamRTResourceFailure", 96)):
            self.assertIn(f"sizeof({typename})=={size}", header)
        handoff = (STARTUP / "resource_handoff.h").read_text()
        self.assertIn("beamrtResourceHandoffABI=7", handoff)
        self.assertIn("sizeof(BeamRTResourceRecordReceipt)==32768", handoff)
        self.assertIn("sizeof(BeamRTResourceReply)==33160", handoff)
        profile = (STARTUP / "resource_profile.h").read_text()
        for guard in ("beamrtResourceStorageLegacy=0,beamrtResourceStorageCompact=1",
                      "beamrtResourceStoragePayloadLimit=256,beamrtResourceStorageByteLimit=47104",
                      "profile==beamrtResourceStorageLegacy?256u:profile==beamrtResourceStorageCompact?1024u:profile==beamrtResourceStorageInterned?4096u:0u",
                      "beamrtResourceProfileConfigABI=2", "sizeof(BeamRTResourceProfileConfig)==24",
                      "sizeof(BeamRTResourceStorageSnapshot)==64", "sizeof(BeamRTResourceStorageFailure)==104"):
            self.assertIn(guard, profile)

    def test_profile_metrics_are_exact_and_current_failure_join_is_monotone(self):
        profile = (STARTUP / "resource_profile.h").read_text()
        metrics = body(profile, "inline bool beamrtResourceStorageSnapshotValid(")
        for guard in ("s.profile==profile", "s.locationLimit==beamrtResourceLocationLimit(profile)",
                      "s.payloadLimit==beamrtResourceStoragePayloadLimit", "s.byteLimit==beamrtResourceStorageByteLimit",
                      "!s.reserved[0] && !s.reserved[1] && !s.reserved[2]", "s.payloads<=s.locations",
                      "s.directoryBytes==beamrtResourceDirectoryBytes(profile)", "s.locationBytes==beamrtResourceLocationBytes(profile)",
                      "s.heapLimit==beamrtResourceStorageHeapLimit(profile)", "s.heaps<=s.heapLimit", "s.heaps<=s.locations",
                      "uint64_t(s.usedBytes)==uint64_t(s.directoryBytes)+uint64_t(s.locations)*s.locationBytes+uint64_t(s.payloads)*160", "s.usedBytes<=s.byteLimit"):
            self.assertIn(guard, metrics)
        validation = (STARTUP / "resource_storage_validation.h").read_text()
        evidence = body(validation, "inline bool beamrtResourceStorageEvidenceValid(")
        for guard in ("storage.locations==status.views", "beamrtResourceStorageFailureValid(first,failure,status,profile)",
                      "!failure.kind", "storage.locations<=first.atFailure.locations",
                      "storage.payloads<=first.atFailure.payloads", "storage.heaps<=first.atFailure.heaps", "storage.usedBytes<=first.atFailure.usedBytes"):
            self.assertIn(guard, evidence)
        first = body(validation, "inline bool beamrtResourceStorageFailureValid(")
        self.assertLess(first.index("if(e.attemptedLocations>s.locationLimit)return false"),
                        first.index("if(f.kind==BeamRTResourceFailureViewPayloadCapacity)"))
        for guard in ("s.locations!=f.views", "e.attemptedLocations!=s.locations+1",
                      "uint64_t(s.usedBytes)+s.locationBytes+(e.attemptedPayloads>s.payloads?160:0)",
                      "e.attemptedPayloads<=s.payloadLimit", "e.requiredBytes==f.attemptedCount"):
            self.assertIn(guard, first)
        self.assertLess(first.index("if(e.attemptedHeaps>s.heapLimit)return false"),
                        first.index("if(f.kind==BeamRTResourceFailureViewPayloadCapacity)"))

    def test_explicit_physical_accounting_does_not_repurpose_reserved_fields(self):
        profile = (STARTUP / "resource_profile.h").read_text()
        for guard in ("usedBytes,reserved[3]", "uint32_t directoryBytes,locationBytes,heaps,heapLimit",
                      "uint32_t attemptedLocations,attemptedPayloads,requiredBytes,reserved", "uint32_t attemptedHeaps,reserved2",
                      "profile==beamrtResourceStorageInterned?14u:24u", "profile==beamrtResourceStorageInterned?512u:0u",
                      "profile==beamrtResourceStorageInterned?32u:0u"):
            self.assertIn(guard, profile)
        validation = (STARTUP / "resource_storage_validation.h").read_text()
        for guard in ("e.abi!=2", "e.reserved || e.reserved2", "e.attemptedHeaps!=s.heaps && e.attemptedHeaps!=s.heaps+1",
                      "s.heaps==s.heapLimit", "e.attemptedHeaps==s.heapLimit+1", "e.attemptedHeaps==f.attemptedCount"):
            self.assertIn(guard, validation)
        tracker = (STARTUP / "resource_tracker.cpp").read_text()
        snapshot = body(tracker, "static BeamRTResourceStorageSnapshot storageSnapshot(")
        for guard in ("out.abi=2", "out.directoryBytes=beamrtResourceDirectoryBytes(c.profile)",
                      "out.locationBytes=beamrtResourceLocationBytes(c.profile)", "out.heaps=held.heaps", "out.heapLimit=beamrtResourceStorageHeapLimit(c.profile)"):
            self.assertIn(guard, snapshot)

    def test_public_interned_cpu_evidence_exercises_empty_and_capacity_guards(self):
        evidence = body(self.fixture, "void internedEvidence(")
        for guard in ("status.abi=3", "failure.abi=3", "evidence.abi=2", "snapshot(0,0,0)",
                      "interned population accepted as an old profile", "which<12", "mutation<11",
                      "BeamRTResourceFailureViewHeapCapacity", "heaps+(which==2?1u:0u)",
                      "post-failure occupied heap growth accepted", "payload cause hid earlier heap exhaustion",
                      "byte cause hid earlier heap/payload exhaustion", "byte cause hid earlier payload exhaustion",
                      "!beamrtResourceStorageSnapshotValid(snapshot(4096,1,1),profile)"):
            self.assertIn(guard, evidence)

    def test_isolated_build_and_ci_run_only_the_cpu_experiment(self):
        for guard in ("CPU-only replacement-storage experiment", "descriptor_view_store_fixture.cpp", "descriptor_view_store.h",
                      "'resource_tracker.h','resource_view_validation.h'", "/W4 /WX", "/std:c++17", "if($RunTest)",
                      "artifacts.sha256.csv", "no install attempted"):
            self.assertIn(guard, self.build)
        self.assertNotRegex(self.build, r"(?i)(?:start-process|beamng\.exe|reshade|/dll|build\.ps1|worker\.cpp|capture\.cpp)")
        self.assertIn("std::make_unique<ds::Store>", self.fixture)
        workflow = (ROOT / ".github/workflows/beamrt-native-worker.yml").read_text()
        self.assertGreaterEqual(workflow.count("'tools/tests/test_descriptor_view_store_contracts.py'"), 2)
        self.assertIn("python -B tools/tests/test_descriptor_view_store_contracts.py", workflow)
        self.assertIn("./native/startup/build_descriptor_view_store.ps1 -RunTest", workflow)
        main = body(self.fixture, "int main(")
        for function in ("legacyDistinct", "compactFanout", "redundancyCapacityControl", "exactPayloadBytes",
                         "snapshotRetirement", "boundedFailures", "invalidQueriesAndMutations", "randomizedReference", "profiledEvidence",
                         "internedEvidence", "internedCopyEvidence"):
            self.assertIn(function+"()", main)
        self.assertIn("12 CPU-only groups", main)
        self.assertIn('#include "resource_storage_validation.h"', self.fixture)


if __name__ == "__main__":
    unittest.main()
