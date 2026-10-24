"""CPU-only first-invalidation evidence guards; no DLL or game is loaded here.

These source regressions complement the actual native overlap/capacity fixtures.
They do not establish chronological API entry, GPU completion, or game coverage.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


def body(source, marker):
    """Extract one brace-delimited C++ function/struct for scoped assertions."""
    start = source.index("{", source.index(marker))
    depth = 1
    end = start + 1
    while depth:
        if source[end] == "{":
            depth += 1
        elif source[end] == "}":
            depth -= 1
        end += 1
    return source[start + 1:end - 1]


class ResourceFirstFailureContracts(unittest.TestCase):
    def source(self, name):
        return (ROOT / "native/startup" / name).read_text()

    def test_separate_typed_diagnostics_do_not_change_old_metadata_abi(self):
        header = self.source("resource_tracker.h")
        for guard in ("beamrtResourceABI=1", "sizeof(BeamRTResourceStatus)==88",
                      "sizeof(BeamRTResourceView)==168", "sizeof(BeamRTBufferCandidate)==112",
                      "sizeof(BeamRTResourceFailure)==96", "sizeof(BeamRTResourceDiagnostics)==184",
                      "BeamRTResourceStatus status;BeamRTResourceFailure firstFailure;",
                      "not absolute API-entry", "BeamRT_ResourcesFirstFailure", "BeamRT_ResourcesDiagnostics"):
            self.assertIn(guard, header)
        record = self.source("resource_record.h")
        self.assertIn("beamrtResourceDrawABI=5", record)
        self.assertIn("sizeof(BeamRTResourceDrawObservation)==3000", record)
        self.assertIn("BeamRTResourceFailure firstFailure;", record)

    def test_every_unhealthy_assignment_uses_one_immutable_bounded_latch(self):
        code = self.source("resource_tracker.cpp")
        latch = body(code, "static void fail(")
        self.assertEqual(len(re.findall(r"\.healthy\s*=\s*0\b", code)), 1)
        self.assertIn("c.status.healthy=0;if(c.firstFailure.kind)return;", latch)
        self.assertIn("f.bytes=sizeof(f);f.abi=beamrtResourceStatusABI(c.profile);f.kind=kind;f.method=c.method", latch)
        for field in ("callerThread", "activeCallbacks", "capacityLimit", "attemptedCount",
                      "callbackOrdinal", "observedCallbacks", "overlaps", "pressure", "serial",
                      "liveHeaps", "liveResources", "views", "drawTokens"):
            self.assertIn("f." + field, latch)
        for forbidden in ("new ", "make_shared", "push_back", "CreateFile", "WriteFile",
                          "CreateThread", "CreateEvent", "OutputDebugString", "printf", "std::cout", "std::cerr"):
            self.assertNotIn(forbidden, latch)
        # Only startup may initialize the typed empty event; the failure latch
        # itself owns the one subsequent write to the event fields.
        for forbidden in ("c.firstFailure={}", "c->firstFailure={}", "resident->firstFailure={}"):
            self.assertNotIn(forbidden, code)

    def test_callback_provenance_is_per_call_and_locked_not_global_entry_order(self):
        code = self.source("resource_tracker.cpp")
        call = body(code, "struct Call {")
        self.assertIn("uint64_t ordinal=0", call)
        self.assertLess(call.index("std::lock_guard<std::mutex> g(c->mutex)"),
                        call.index("ordinal=c->status.callbacks"))
        self.assertLess(call.index("Site site(*c,method,ordinal)"), call.index("tick(*c,c->status.callbacks)"))
        observe = body(code, "template<class F>static void observe(")
        self.assertEqual(observe.count("std::lock_guard<std::mutex> g(call.c->mutex)"), 2)
        self.assertEqual(observe.count("Site site(*call.c,call.method,call.ordinal)"), 2)
        site = body(code, "struct Site {")
        self.assertIn("c.method=m;c.callbackOrdinal=o", site)
        self.assertIn("c.method=method;c.callbackOrdinal=ordinal", site)
        for method in ("CreateHeap", "CreateSRV", "CreateRTV", "CreateCBV", "CreateUAV",
                       "CopySimple", "CopyRanges", "Committed", "Placed", "Reserved"):
            self.assertIn("Call call(d,BeamRTResourceMethod" + method + ")", code)
        enum = body(self.source("resource_tracker.h"), "enum BeamRTResourceMethod")
        self.assertTrue(enum.strip().startswith("BeamRTResourceMethodNone=0,BeamRTResourceMethodCreateHeap"))

    def test_overlap_uses_observed_entry_count_not_a_later_decremented_sample(self):
        code = self.source("resource_tracker.cpp")
        call = body(code, "struct Call {")
        self.assertIn("const auto active=c->inFlight.fetch_add(1)", call)
        self.assertIn("fail(*c,BeamRTResourceFailureOverlap,0,active+1)", call)
        latch = body(code, "static void fail(")
        self.assertIn("activeAtEntry==UINT_MAX?c.inFlight.load():activeAtEntry", latch)
        self.assertIn("if(active){tick(*c,c->status.overlaps)", call)

    def test_capacity_defaults_remain_small_and_profile_pressure_uses_actual_units(self):
        code = self.source("resource_tracker.cpp")
        header = self.source("resource_tracker.h")
        for symbol, value in (("Heap", 32), ("Object", 128), ("View", 256), ("Copy", 64), ("Draw", 16)):
            self.assertRegex(header, rf"beamrtResource{symbol}Limit\s*=\s*{value}\b")
        for kind, limit in (("Heap", "Heap"), ("Object", "Object"), ("Draw", "Draw")):
            self.assertIn(f"pressure(c,BeamRTResourceFailure{kind}Capacity,beamrtResource{limit}Limit)",
                          code.replace("pressure(*c,", "pressure(c,"))
        pressure = body(code, "static void pressure(")
        self.assertIn("tick(c,c.status.pressure);fail(c,kind,limit,UINT_MAX,attempted)", pressure)
        self.assertIn("f.attemptedCount=attempted?attempted:limit?limit+1:0", body(code, "static void fail("))
        for guard in ("BeamRTResourceFailureViewCapacity,beamrtResourceLocationLimit(c.profile),held.attemptedLocations",
                      "BeamRTResourceFailureViewPayloadCapacity,beamrtResourceStoragePayloadLimit,held.attemptedPayloads",
                      "BeamRTResourceFailureViewByteCapacity,beamrtResourceStorageByteLimit,held.requiredBytes"):
            self.assertIn(guard, body(code, "static void write("))

    def test_first_failure_and_start_status_are_copied_as_one_locked_snapshot(self):
        code = self.source("resource_tracker.cpp")
        query = body(code, 'extern "C" HRESULT WINAPI BeamRT_ResourcesFirstFailure(')
        self.assertIn("if(!out || bytes!=sizeof(*out))return E_INVALIDARG;*out={}", query)
        self.assertIn("std::lock_guard<std::mutex> g(c->mutex);*out=c->firstFailure", query)
        self.assertIn("return out->kind?S_OK:S_FALSE", query)
        paired = body(code, 'extern "C" HRESULT WINAPI BeamRT_ResourcesDiagnostics(')
        self.assertIn("std::lock_guard<std::mutex> g(c->mutex);out->status=currentStatus(*c);out->firstFailure=c->firstFailure", paired)
        bridge = body(self.source("resource_handoff.cpp"), "HRESULT BeamRT_ResourceStartFromPayload(")
        self.assertIn("BeamRT_ResourcesDiagnosticsProfiled(&diagnostics,sizeof(diagnostics))", bridge)
        self.assertIn("result,resourceMode,0,resourceProfile,0", bridge)
        self.assertIn("diagnostics.status,diagnostics.firstFailure,diagnostics.storage,diagnostics.storageFailure", bridge)
        self.assertNotIn("BeamRT_ResourcesStatus(", bridge)
        self.assertNotIn("BeamRT_ResourcesFirstFailure(", bridge)

    def test_lookup_failure_cannot_publish_stale_successful_metadata(self):
        code = self.source("resource_tracker.cpp")
        finish = body(code, 'extern "C" HRESULT WINAPI BeamRT_ResourcesFinishDraw(')
        self.assertEqual(finish.count("out->firstFailure=c->firstFailure"), 2)
        self.assertEqual(finish.count("std::lock_guard<std::mutex> g(c->mutex)"), 1)
        self.assertEqual(finish.count("out->storage=storageSnapshot(*c);out->storageFailure=c->storageFailure"), 2)
        self.assertLess(finish.index("std::lock_guard<std::mutex> g(c->mutex)"), finish.index("out->storage=storageSnapshot(*c)"))
        self.assertLess(finish.index("out->firstFailure=c->firstFailure"), finish.index("if(!tokenMatches"))
        cleanup = body(finish, "if(!c->status.healthy)")
        for guard in ("out->intervalAccepted=0", "out->result=HRESULT_FROM_WIN32(ERROR_NOT_READY)",
                      "for(auto& v:out->srvs)v={}", "for(auto& v:out->rtvs)v={}", "out->cbv={}",
                      "out->cbvResult=S_FALSE", "for(auto& h:out->srvResults)h=S_FALSE",
                      "for(auto& h:out->rtvResults)h=S_FALSE", "return out->result"):
            self.assertIn(guard, cleanup)

    def test_profile_storage_first_cause_is_immutable_and_same_lock_as_current_counts(self):
        code = self.source("resource_tracker.cpp")
        latch = body(code, "static void fail(")
        self.assertLess(latch.index("if(c.firstFailure.kind)return"), latch.index("storage.atFailure=storageSnapshot(c)"))
        for guard in ("storage.present=1", "if(beamrtResourceStorageCapacityKind(kind))",
                      "storage.attemptedLocations=held.attemptedLocations", "storage.attemptedPayloads=held.attemptedPayloads",
                      "storage.requiredBytes=held.requiredBytes"):
            self.assertIn(guard, latch)
        paired = body(code, 'extern "C" HRESULT WINAPI BeamRT_ResourcesDiagnosticsProfiled(')
        self.assertEqual(paired.count("std::lock_guard<std::mutex> g(c->mutex)"), 1)
        self.assertLess(paired.index("std::lock_guard<std::mutex> g(c->mutex)"), paired.index("out->status=currentStatus(*c)"))
        self.assertIn("out->firstFailure=c->firstFailure", paired)
        self.assertIn("out->storage=storageSnapshot(*c);out->storageFailure=c->storageFailure", paired)

    def test_validators_require_consistent_first_cause_and_refuse_prior_transport(self):
        header = self.source("resource_tracker.h")
        validator = body(header, "inline bool beamrtResourceFailureValid(")
        for guard in ("f.bytes!=sizeof(f)", "f.abi!=beamrtResourceStatusABI(profile)", "f.kind>=BeamRTResourceFailureKindCount",
                      "f.reserved || f.reserved2", "return s.healthy", "if(s.healthy",
                      "f.method>=BeamRTResourceMethodCount", "f.callbackOrdinal>f.observedCallbacks",
                      "f.observedCallbacks>s.callbacks", "f.overlaps>s.overlaps", "f.pressure>s.pressure",
                      "f.serial>s.serial", "f.activeCallbacks<2", "!f.callbackOrdinal", "!f.overlaps",
                      "f.method>BeamRTResourceMethodReserved", "if(limit && !f.pressure)",
                      "f.capacityLimit==limit", "f.attemptedCount==(limit?limit+1:0)"):
            self.assertIn(guard, validator)
        transport = self.source("resource_handoff.h")
        self.assertIn("beamrtResourceFailureValid(o.firstFailure,o.status,expectedProfile)", transport)
        self.assertIn("p->abi==beamrtResourceHandoffABI", transport)
        start = body(transport, "inline bool beamrtResourceStartReceiptValid(")
        self.assertIn("beamrtResourceFailureValid(r.firstFailure,s,expectedProfile)", start)
        host = self.source("launcher.cpp")
        for guard in ("for(const auto prior:{1u,2u,3u,4u,5u,6u})", "invalid.abi=prior", "prior resource ABI accepted",
                      "beamrtResourceStartReceiptValid(resourceReady,process.dwProcessId,process.dwThreadId,options.resourceMode,options.resourceProfile)"):
            self.assertIn(guard, host)

    def test_unhealthy_startup_event_is_saved_before_status_refusal(self):
        host = self.source("launcher.cpp")
        self.assertLess(host.index("beamrtResourceStartReceiptValid(resourceReady,process.dwProcessId,process.dwThreadId,options.resourceMode,options.resourceProfile)"),
                        host.index('saveThreadEvidence(options.bindingOutput+L".resources-start.bin"'))
        self.assertLess(host.index('saveThreadEvidence(options.bindingOutput+L".resources-start.bin"'),
                        host.index("if(FAILED(resourceReady.result) || !resourceReady.status.enabled || !resourceReady.status.healthy"))
        for guard in ("coherent unhealthy startup evidence lost", "malformed startup first failure accepted",
                      "invalid.firstFailure.method=BeamRTResourceMethodNone", "invalid.status.healthy=1"):
            self.assertIn(guard, host)

    def test_real_native_overlap_fixture_preserves_first_cause_and_off_forwarding(self):
        fixture = self.source("resource_fixture.cpp")
        for guard in ("SRVGate gate(device.Get())", "WaitForSingleObject(gate.release,10000)",
                      "gate.native(d,r,v,dst)", "worker=std::thread", "WaitForSingleObject(entered,10000)",
                      "returnedError==nativeError.load()", "if(pressureKind==4)overlap()",
                      "failure.kind==kinds[pressureKind]", "failure.method==methods[pressureKind]",
                      "failure.callbackOrdinal==failure.observedCallbacks", "const auto firstFailure=failure",
                      "later overlap or native pressure replaced first failure",
                      "refused draw omitted immutable first failure", "17 malformed first failure receipts rejected",
                      "wrong-sized first failure buffer modified", "healthy first failure was invented",
                      "OFF or cached native forwarding replaced first failure", "gate.restore()"):
            self.assertIn(guard, fixture)
        self.assertLess(fixture.index("SRVGate gate(device.Get())"), fixture.index("BeamRT_ResourcesStart(device.Get())"))
        build = self.source("build_resource_tracker.ps1")
        self.assertIn("@('heap','resource','view','draw','overlap','copy','copy-prefix','copy-boundary','copy-simple','copy-explicit')", build)
        self.assertIn("'--overlap-first'", build)


if __name__ == "__main__":
    unittest.main()
