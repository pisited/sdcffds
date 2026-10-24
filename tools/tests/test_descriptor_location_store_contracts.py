"""Exact-location and explicit integration guards, not live-game/GPU proof."""
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


class DescriptorLocationContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.header = (STARTUP / "descriptor_location_store.h").read_text()
        cls.fixture = (STARTUP / "descriptor_location_store_fixture.cpp").read_text()
        cls.build = (STARTUP / "build_descriptor_location_store.ps1").read_text()

    def test_new_representation_is_only_selected_by_explicit_interned_profile(self):
        self.assertIn("namespace beamrt::descriptor_locations", self.header)
        for name in ("resource_tracker.cpp", "resource_handoff.h", "resource_handoff.cpp", "launcher.cpp", "build.ps1"):
            self.assertNotIn('"descriptor_location_store.h"', (STARTUP / name).read_text())
        self.assertIn("beamrtResourceHandoffABI=7", (STARTUP / "resource_handoff.h").read_text())
        self.assertIn("compactLocationLimit=1024", (STARTUP / "descriptor_view_store.h").read_text())
        tracker = (STARTUP / "resource_tracker.cpp").read_text()
        self.assertIn('#include "resource_view_storage.h"', tracker)
        wrapper = (STARTUP / "resource_view_storage.h").read_text()
        for guard in ('#include "descriptor_location_store.h"', "namespace beamrt::resource_view_storage",
                      "profile==beamrtResourceStorageLegacy)backend_.emplace<old::Store>(old::legacyLimits)",
                      "profile==beamrtResourceStorageCompact)backend_.emplace<old::Store>(old::compactLimits)",
                      "profile==beamrtResourceStorageInterned)backend_.emplace<interned::Store>(interned::defaultLimits)"):
            self.assertIn(guard, wrapper)

    def test_wrapper_owns_one_arena_and_maps_old_enums_explicitly(self):
        wrapper = (STARTUP / "resource_view_storage.h").read_text()
        self.assertIn("std::variant<std::monostate,old::Store,interned::Store> backend_", wrapper)
        self.assertIn("sizeof(Store)<=interned::arenaBytes+128", wrapper)
        for result in ("Ok", "NotFound", "Invalid", "Capacity", "Unhealthy"):
            self.assertIn(f"case old::Result::{result}:return Result::{result}", wrapper)
        for cause in ("None", "Limits", "View", "Revision", "HeapId", "ResourceId", "LocationCapacity", "PayloadCapacity", "ByteCapacity"):
            self.assertIn(f"case old::Cause::{cause}:return Cause::{cause}", wrapper)
        self.assertNotIn("static_cast<Result>", wrapper)
        self.assertNotIn("static_cast<Cause>", wrapper)
        self.assertIn("f.locations,f.payloads,0,f.usedBytes,f.attemptedLocations,f.attemptedPayloads,0,f.requiredBytes", wrapper)
        self.assertIn("return {s.locations,s.payloads,0,s.usedBytes,s.healthy}", wrapper)

    def test_directory_is_in_fixed_arena_and_all_four_counts_are_explicit(self):
        for guard in ("arenaBytes=47104,directoryBytes=512,locationBytes=14,payloadBytes=160",
                      "logicalLocationLimit=4096,heapLimit=32", "std::array<uint8_t,arenaBytes> arena_",
                      "sizeof(Heap)==16 && directoryBytes==heapLimit*sizeof(Heap)",
                      "uint32_t locations,payloads,heaps,usedBytes", "sizeof(Store)<=arenaBytes+80"):
            self.assertIn(guard, self.header)
        used = body(self.header, "uint32_t used(")
        self.assertIn("directoryBytes+payloads_*payloadBytes+locations_*locationBytes", used)
        code = re.sub(r"//[^\n]*|/\*.*?\*/", "", self.header, flags=re.S)
        for forbidden in ("std::vector", "new ", "malloc(", "realloc(", "#pragma pack", "ComPtr"):
            self.assertNotIn(forbidden, code)

    def test_unaligned_record_uses_field_copies_and_full_width_values(self):
        read = body(self.header, "detail::Location location(")
        write = body(self.header, "void location(")
        for guard in ("bytes+1,1", "bytes+2,4", "bytes+6,8"):
            self.assertIn(guard, read)
        for guard in ("bytes+1,&value.payload,1", "bytes+2,&value.index,4", "bytes+6,&value.revision,8"):
            self.assertIn(guard, write)
        self.assertNotIn("sizeof(value)", write)
        self.assertNotIn("reinterpret_cast", read + write)
        self.assertIn("uint64_t id=0", self.header)
        self.assertIn("heap(i).id==id", body(self.header, "uint32_t heapSlot("))
        self.assertIn("raw::decode(held.key,{h.id,value.revision,value.index,value.payload},out)", self.header)

    def test_key_snapshot_and_post_clear_slot_lookup_precede_allocation(self):
        put = body(self.header, "Result put(")
        self.assertLess(put.index("raw::encode(view)"), put.index("eraseAt(old)"))
        self.assertLess(put.index("eraseAt(old)"), put.index("auto h=heapSlot(id)"))
        self.assertLess(put.index("eraseAt(old)"), put.index("payload(i).key==key"))
        self.assertIn("view.revision<=lastRevision_", put)
        self.assertIn("view.heapId=id", put)
        self.assertIn("std::memcpy(&view,&input,sizeof(view))", put)
        for field in ("attemptedLocations", "attemptedPayloads", "attemptedHeaps"):
            self.assertIn(field, put)
        checks = [put.index("if(" + key) for key in ("attemptedLocations>", "attemptedHeaps>", "attemptedPayloads>", "required>")]
        self.assertEqual(checks, sorted(checks))
        self.assertLess(checks[-1], put.index("heap(h,{id,0,0})"))
        self.assertLess(checks[-1], put.index("static_cast<uint8_t>(shared)"))

    def test_all_moved_payload_references_and_last_heap_reference_are_repaired(self):
        erase = body(self.header, "void eraseAt(")
        for guard in ("location(i,location(lastLocation))", "--held.references", "payload(old.payload,payload(lastPayload))",
                      "j<locations_", "value.payload==lastPayload", "value.payload=old.payload",
                      "--h.references", "if(h.references)", "heap(old.heap,{})", "--heaps_"):
            self.assertIn(guard, erase)
        self.assertLess(erase.index("value.payload=old.payload"), erase.index("payload(lastPayload,{})"))

    def test_strict_failure_and_diagnostic_reaping_remain_distinct(self):
        poison = body(self.header, "Result poison(")
        self.assertIn("if(healthy())failure_=", poison)
        self.assertIn("locations_,payloads_,heaps_,used()", poison)
        for marker in ("Result put(", "Result erase(", "Result retireHeap(", "Result retireResource("):
            self.assertIn("if(!healthy())return Result::Unhealthy", body(self.header, marker))
        self.assertIn("out={};if(!healthy())return Result::Unhealthy", body(self.header, "Result get("))
        for marker in ("Result reapDeadHeap(", "Result reapDeadResource("):
            reap = body(self.header, marker)
            self.assertNotIn("poison(", reap)
            self.assertNotIn("lastRevision_=", reap)
            self.assertNotIn("if(!healthy())", reap)
            self.assertIn("if(!id)return Result::Invalid", reap)

    def test_fixture_uses_an_independent_map_and_labels_surrogates(self):
        self.assertIn("std::map", self.fixture)
        self.assertIn("5000", self.fixture)
        self.assertIn("168", self.fixture)
        self.assertIn("surrogate", self.fixture.lower())
        self.assertNotIn("raw::encode", self.fixture)
        for forbidden in ("LoadLibrary", "CreateDevice(", "BeamRT_ResourcesStart(", "GetGPUVirtualAddress("):
            self.assertNotIn(forbidden, self.fixture)

    def test_builder_and_ci_remain_isolated_cpu_only(self):
        for guard in ("descriptor_location_store_fixture.cpp", "descriptor_location_store.h", "descriptor_view_store.h",
                      "/W4 /WX", "/std:c++17", "/O2", "if($RunTest)", "Guid]::NewGuid", "artifacts.sha256.csv"):
            self.assertIn(guard, self.build)
        self.assertNotRegex(self.build, r"(?i)(start-process|loadlibrary|/LD\b|/DLL\b|native/capture|native/worker)")
        workflow = (ROOT / ".github/workflows/beamrt-native-worker.yml").read_text()
        self.assertEqual(workflow.count("'tools/tests/test_descriptor_location_store_contracts.py'"), 2)
        self.assertIn("python -B tools/tests/test_descriptor_location_store_contracts.py", workflow)
        self.assertIn("./native/startup/build_descriptor_location_store.ps1 -RunTest", workflow)


if __name__ == "__main__":
    unittest.main()
