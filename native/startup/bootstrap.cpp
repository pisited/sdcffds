#include "startup_contract.h"
#include <detours.h>

// POD only: no static C++ constructors, renderer libraries or unload callbacks.
static volatile LONG attached=0;
static DWORD attachThread=0;
extern "C" __declspec(dllexport) BOOL WINAPI BeamRT_StartupQuery(BeamRTStartupStatus* out,DWORD bytes) {
    if(!out || bytes!=sizeof(*out))return FALSE;
    *out={sizeof(*out),1,static_cast<uint32_t>(InterlockedCompareExchange(&attached,0,0)),
          GetCurrentProcessId(),attachThread,0,0,0};
    return out->attached==1;
}
BOOL WINAPI DllMain(HINSTANCE,DWORD reason,LPVOID) {
    if(reason!=DLL_PROCESS_ATTACH)return TRUE;
    if(DetourIsHelperProcess())return TRUE;
    DWORD bytes=0;
    const auto payload=static_cast<const BeamRTStartupPayload*>(DetourFindPayloadEx(beamrtStartupGuid,&bytes));
    if(!beamrtStartupPayloadValid(payload,bytes,GetCurrentProcessId()))return FALSE;
    const uint64_t eventValue=payload->receiptEvent;
    // Required restoration of Detours' temporary startup import-table edit.
    // No device creation, waits, threads, file logging, capture or GPU work here.
    if(!DetourRestoreAfterWith())return FALSE;
    attachThread=GetCurrentThreadId();InterlockedExchange(&attached,1);
    const auto receipt=reinterpret_cast<HANDLE>(static_cast<ULONG_PTR>(eventValue));
#ifdef BEAMRT_STARTUP_TEST_NO_RECEIPT
    const BOOL signalled=TRUE; // disposable test DLL only; still attach and query normally
#else
    const BOOL signalled=SetEvent(receipt);
#endif
    CloseHandle(receipt);
    return signalled;
}
