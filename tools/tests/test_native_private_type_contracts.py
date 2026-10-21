"""Private C++ type identity and co-linked regression wiring, without loading DLLs.

These source guards check lexical coverage, not merely a namespace's presence.
The real startup object-pressure fixture remains necessary to exercise the
production link, native allocations, unchanged GPU output, and OFF restoration.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


def cpp_mask(source):
    """Hide comments and literals while retaining offsets, braces, and newlines."""
    pattern = r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\''
    return re.sub(pattern, lambda m: re.sub(r"[^\n]", " ", m.group()), source)


def private_intervals(mask):
    """Find the actual balanced bodies of anonymous namespaces."""
    intervals = []
    for match in re.finditer(r"\bnamespace\s*\{", mask):
        start = match.end() - 1
        depth, end = 1, start + 1
        while depth and end < len(mask):
            depth += (mask[end] == "{") - (mask[end] == "}")
            end += 1
        if depth:
            raise AssertionError("unterminated anonymous namespace")
        intervals.append((start, end))
    return intervals


def is_private(offset, intervals):
    return any(start < offset < end for start, end in intervals)


def brace_depth(mask, offset):
    return mask[:offset].count("{") - mask[:offset].count("}")


class NativePrivateTypeContracts(unittest.TestCase):
    def source(self, name):
        return (ROOT / "native/startup" / name).read_text()

    def assert_types_private(self, name, names):
        mask = cpp_mask(self.source(name))
        intervals = private_intervals(mask)
        for typename in names:
            # Include forward declarations and __declspec(uuid(...)) types.
            declarations = list(re.finditer(
                rf"\b(?:struct|class)\s+(?:__declspec\s*\([^;{{}}]*?\)\s+)?{typename}\b",
                mask))
            self.assertTrue(declarations, (name, typename, "missing declaration"))
            for declaration in declarations:
                self.assertTrue(is_private(declaration.start(), intervals),
                                (name, typename, "externally linkable implementation type"))

    def test_scope_guard_ignores_comments_strings_and_decoy_namespaces(self):
        source = '''
            // namespace { struct Context {}; }
            const char* text = "namespace { struct Context {}; }";
            namespace { struct Slot {}; }
            struct Context {};
            namespace { struct Context; struct Context { void f(){if(true){}} }; }
        '''
        mask = cpp_mask(source)
        intervals = private_intervals(mask)
        declarations = list(re.finditer(r"\bstruct\s+Context\b", mask))
        self.assertEqual(len(declarations), 3)
        self.assertEqual([is_private(m.start(), intervals) for m in declarations],
                         [False, True, True])
        self.assertFalse(is_private(mask.index("const char"), intervals))
        with self.assertRaisesRegex(AssertionError, "unterminated"):
            private_intervals(cpp_mask("namespace { struct Context {};"))

    def test_resource_implementation_types_are_translation_unit_private(self):
        self.assert_types_private("resource_tracker.cpp", (
            "Life", "LifeTag", "Object", "Heap", "Slot", "Context",
            "Site", "Call", "LastError"))

    def test_shared_descriptor_store_types_have_a_unique_header_namespace(self):
        tracker = cpp_mask(self.source("resource_tracker.cpp"))
        self.assertNotRegex(tracker, r"\bstruct\s+View\b")
        self.assertIn("viewStore::Store views;", tracker)
        self.assertIn("views(selectedProfile)", tracker)
        mask = cpp_mask(self.source("descriptor_view_store.h"))
        namespace = re.search(r"\bnamespace\s+beamrt::descriptor_store\s*\{", mask)
        self.assertIsNotNone(namespace)
        start = namespace.end() - 1
        depth, end = 1, start + 1
        while depth:
            depth += (mask[end] == "{") - (mask[end] == "}")
            end += 1
        for typename in ("Store", "Payload", "Location", "Limits", "Failure", "Stats"):
            declarations = list(re.finditer(rf"\b(?:class|struct)\s+{typename}\b", mask))
            self.assertTrue(declarations, typename)
            for declaration in declarations:
                self.assertTrue(start < declaration.start() < end, typename)

    def test_binding_types_and_optional_draw_scope_are_translation_unit_private(self):
        self.assert_types_private("gi_bindings.cpp", (
            "ResourceDrawScope", "Slot", "State", "Context", "DecoderLease",
            "TagInterface", "Tag", "Guard", "LastError"))

    def test_interned_and_wrapper_types_have_distinct_header_namespaces(self):
        for filename, namespace_name, names in (
            ("descriptor_location_store.h", "beamrt::descriptor_locations", ("Heap", "Location", "Store", "Limits", "Failure", "Stats")),
            ("resource_view_storage.h", "beamrt::resource_view_storage", ("Store",)),
        ):
            mask = cpp_mask(self.source(filename))
            namespace = re.search(rf"\bnamespace\s+{re.escape(namespace_name)}\s*\{{", mask)
            self.assertIsNotNone(namespace)
            start = namespace.end() - 1
            depth, end = 1, start + 1
            while depth:
                depth += (mask[end] == "{") - (mask[end] == "}")
                end += 1
            for typename in names:
                declarations = list(re.finditer(rf"\b(?:class|struct)\s+{typename}\b", mask))
                self.assertTrue(declarations, (filename, typename))
                for declaration in declarations:
                    self.assertTrue(start < declaration.start() < end, (filename, typename))

    def test_audit_implementation_types_are_translation_unit_private(self):
        self.assert_types_private("pipeline_audit.cpp", (
            "Slot", "Audit", "Lock", "RestoreError"))

    def test_public_includes_sdk_declarations_and_c_exports_stay_global(self):
        for name, sdk, export in (
            ("resource_tracker.cpp", "beamrtResourceSDKSlot", "BeamRT_ResourcesStart"),
            ("gi_bindings.cpp", "beamrtBindingSDKSlot", "BeamRT_BindingsStart"),
            ("pipeline_audit.cpp", "beamrtPipelineSDKSlot", "BeamRT_PipelineAuditStart"),
        ):
            source = self.source(name)
            mask = cpp_mask(source)
            for match in re.finditer(r"^\s*#\s*include\b", source, re.MULTILINE):
                self.assertEqual(brace_depth(mask, match.start()), 0,
                                 (name, "header included inside private scope"))
            declarations = list(re.finditer(r'\bextern\s+"C"\s+', source))
            self.assertGreaterEqual(len(declarations), 2, name)
            for match in declarations:
                self.assertEqual(brace_depth(mask, match.start()), 0,
                                 (name, "C API or SDK declaration nested in implementation scope"))
            for symbol in (sdk, export):
                self.assertRegex(source, rf'extern\s+"C"[^;{{}}]*\b{symbol}\b')

    def test_private_scope_preserves_versioned_public_layouts_and_legacy_budgets(self):
        expected = {
            "resource_tracker.h": {"BeamRTResourceView": 168, "BeamRTBufferCandidate": 112,
                                   "BeamRTResourceStatus": 88, "BeamRTResourceFailure": 96,
                                   "BeamRTResourceDiagnostics": 184, "BeamRTResourceProfileDiagnostics": 352},
            "resource_profile.h": {"BeamRTResourceProfileConfig": 24, "BeamRTResourceStorageSnapshot": 64,
                                   "BeamRTResourceStorageFailure": 104},
            "resource_record.h": {"BeamRTResourceDrawToken": 24, "BeamRTResourceDrawObservation": 3000},
            "resource_handoff.h": {"BeamRTResourcePayload": 56, "BeamRTResourceStartReceipt": 392,
                                   "BeamRTResourceRecordReceipt": 32768, "BeamRTResourceReply": 33160},
            "resource_copy_diagnostics.h": {"BeamRTResourceCopyRange": 16, "BeamRTResourceCopyHeap": 56,
                                              "BeamRTResourceCopyLane": 400, "BeamRTResourceCopyFailure": 29728},
            "fixture_contract.h": {"BeamRTResourceFixtureReport": 33280},
            "gi_bindings.h": {"BeamRTBindingSnapshot": 1008, "BeamRTBindingStatus": 120},
            "pipeline_audit.h": {"BeamRTPipelineAuditInfo": 200},
        }
        for name, layouts in expected.items():
            source = cpp_mask(self.source(name))
            for typename, size in layouts.items():
                self.assertRegex(source, rf"static_assert\s*\(\s*sizeof\s*\({typename}\)\s*==\s*{size}\b")
        for name, abi in (("resource_tracker.h", "beamrtResourceABI=1"),
                          ("resource_record.h", "beamrtResourceDrawABI=5"),
                          ("resource_handoff.h", "beamrtResourceHandoffABI=7"),
                          ("resource_copy_diagnostics.h", "beamrtResourceCopyFailureABI=3")):
            self.assertIn(abi, self.source(name))
        resource = self.source("resource_tracker.h")
        for symbol, limit in (("Heap", 32), ("Object", 128), ("View", 256), ("Copy", 64), ("Draw", 16)):
            self.assertRegex(resource, rf"beamrtResource{symbol}Limit\s*=\s*{limit}\b")
        self.assertIn("beamrtBindingCommandLimit=64", self.source("gi_bindings.h"))
        self.assertIn("beamrtPipelineLayoutCacheLimit=32", self.source("pipeline_audit.h"))

    def test_production_bootstrap_colinks_all_three_implementations(self):
        build = self.source("build.ps1")
        sources = re.search(r"^\s*\$beamrtBootstrapSources\s*=\s*@\(([^\n]+)\)$", build, re.MULTILINE)
        self.assertIsNotNone(sources)
        for name in ("resource_tracker.cpp", "gi_bindings.cpp", "pipeline_audit.cpp"):
            self.assertIn("'" + name + "'", sources.group(1))
        production = next(line for line in build.splitlines() if "/Febeamrt_startup_bootstrap.dll" in line)
        for flag in ("/W4", "/WX", "/DBEAMRT_PIPELINE_HANDOFF", "/DBEAMRT_BINDING_EMBEDDED",
                     "/DBEAMRT_RESOURCE_EMBEDDED", "@beamrtBootstrapSources"):
            self.assertIn(flag, production)

    def test_integrated_object_pressure_crosses_corrupt_slot_before_exact_capacity(self):
        fixture = self.source("binding_startup_fixture.cpp")
        # Objects remain live: crossing 60 exercises the previously corrupted
        # slot before filling all 128 entries and refusing the 129th metadata row.
        # Fix the starting count to the nine known live fixture resources: a
        # phantom row must not be normalized into a relative-count baseline.
        legacy = fixture[fixture.index('if(resourceMode==L"objects"){'):]
        mask = cpp_mask(legacy)
        baseline = re.search(r"need\s*\(\s*observed\.status\.enabled[^;]*"
                             r"observed\.status\.liveResources\s*==\s*9\b[^;]*;", mask)
        self.assertIsNotNone(baseline, "missing exact known-resource baseline")
        self.assertLess(baseline.start(), mask.index("auto liveCount=observed.status.liveResources"))
        for guard in ("std::vector<ComPtr<ID3D12Resource>> objectPressure", 'resourceMode==L"objects"',
                      "while(liveCount<beamrtResourceObjectLimit)",
                      "objectPressure.push_back(resource(", "observed.status.liveResources==liveCount",
                      "if(liveCount==60)crossedCorruptSlot=true", "crossedCorruptSlot && liveCount==beamrtResourceObjectLimit",
                      "objectFailure.kind==BeamRTResourceFailureObjectCapacity",
                      "objectFailure.method==BeamRTResourceMethodCommitted",
                      "objectFailure.attemptedCount==beamrtResourceObjectLimit+1",
                      "object capacity receipt lost first failure", "resource OFF changed object capacity first failure"):
            self.assertIn(guard, fixture)
        for forbidden in ("objectPressure.clear(", "objectPressure.resize(", "BeamRT_ResourcesStart("):
            self.assertNotIn(forbidden, fixture)
        harness = self.source("process_test.cpp")
        for guard in ("resource-object-pressure-hardware", "resource-object-pressure-warp",
                      'objects.bindingMode=L"resource-objects"', "objects.warp=warp",
                      "objects.resourceObserve=true", "objects.bindingObserve=true",
                      "o.status.liveResources==beamrtResourceObjectLimit",
                      "o.firstFailure.kind==BeamRTResourceFailureObjectCapacity"):
            self.assertIn(guard, harness)
        branch = harness[harness.index("}else if(resources){"):harness.index("}else if(bindings){")]
        self.assertIn("for(bool warp:{false,true})", branch)
        self.assertLess(branch.index("resource-object-pressure-hardware"), branch.index("if(!resourceObjectsOnly)"))

    def test_pressure_path_keeps_native_gpu_output_and_ten_slot_off_restoration(self):
        fixture = self.source("binding_startup_fixture.cpp")
        self.assertIn("report.pixelOK=std::abs(", fixture)
        self.assertIn("resources.pixelAfterOff=std::abs(", fixture)
        self.assertEqual(fixture.count("footprint.Offset)-23)<.00001f"), 2)
        for guard in ("resources.after.restoredSlots==10", "!resources.after.attachedSlots",
                      "!resources.after.enabled", "resource OFF changed GPU pixel"):
            self.assertIn(guard, fixture)
        harness = self.source("process_test.cpp")
        for guard in ("resources.after.restoredSlots==10", "resources.pixelAfterOff==1",
                      "parent resource receipt differs from actual fixture"):
            self.assertIn(guard, harness)

    def test_ci_runs_private_scope_guard_and_integrated_warp_matrix(self):
        workflow = (ROOT / ".github/workflows/beamrt-native-worker.yml").read_text()
        self.assertEqual(workflow.count("- 'tools/tests/test_native_private_type_contracts.py'"), 2)
        self.assertIn("python -B tools/tests/test_native_private_type_contracts.py", workflow)
        self.assertIn("-RunResourceStartupTests -FreshArtifacts -WarpResourceStartupOnly", workflow)


if __name__ == "__main__":
    unittest.main()
