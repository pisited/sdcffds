#define BEAMRT_RESOURCE_BUILD
#define BEAMRT_BINDING_BUILD
#include "resource_handoff.h"
#include <detours.h>
#include <atomic>
static SRWLOCK resourceBridgeLock=SRWLOCK_INIT;
static BeamRTResourceReply* resourceReply=nullptr;static bool resourceAttempted=false,resourceRecorded=false;
static DWORD resourcePid=0;static std::atomic<uint32_t> resourceProbe{0},resourceMode{beamrtResourceAllAllocations},resourceProfile{beamrtResourceStorageLegacy};
uint32_t BeamRT_ResourceProbeBytes(){return resourceProbe.load();}
HRESULT BeamRT_ResourceStartFromPayload(ID3D12Device* device){
    DWORD bytes=0;const auto p=static_cast<const BeamRTResourcePayload*>(DetourFindPayloadEx(beamrtResourceGuid,&bytes));if(!p)return S_FALSE;
    if(!beamrtResourcePayloadValid(p,bytes,GetCurrentProcessId(),GetCurrentThreadId()))return E_INVALIDARG;
    AcquireSRWLockExclusive(&resourceBridgeLock);if(resourceAttempted){ReleaseSRWLockExclusive(&resourceBridgeLock);return HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS);}
    resourceAttempted=true;resourcePid=GetCurrentProcessId();const auto mapping=reinterpret_cast<HANDLE>(static_cast<ULONG_PTR>(p->outputMapping));
    resourceReply=static_cast<BeamRTResourceReply*>(MapViewOfFile(mapping,FILE_MAP_WRITE,0,0,sizeof(BeamRTResourceReply)));CloseHandle(mapping);
    resourceProbe.store(p->cbvProbeBytes);resourceMode=p->mode;resourceProfile=p->profile;ReleaseSRWLockExclusive(&resourceBridgeLock);
    // Called only from the validated binding payload's existing device gate,
    // outside DLL attach and outside either bridge lock.
    const bool interned=p->profile==beamrtResourceStorageInterned;
    const BeamRTResourceProfileConfig config{sizeof(config),interned?beamrtResourceInternedConfigABI:beamrtResourceProfileConfigABI,p->mode,p->profile,{0,0}};
    const auto result=resourceReply && device?(interned?BeamRT_ResourcesStartInterned(device,&config):BeamRT_ResourcesStartProfiled(device,&config)):E_INVALIDARG;
    BeamRTResourceProfileDiagnostics diagnostics{};BeamRT_ResourcesDiagnosticsProfiled(&diagnostics,sizeof(diagnostics));
    const auto event=reinterpret_cast<HANDLE>(static_cast<ULONG_PTR>(p->startEvent));
    AcquireSRWLockExclusive(&resourceBridgeLock);
    if(resourceReply){resourceReply->start={sizeof(BeamRTResourceStartReceipt),beamrtResourceHandoffABI,resourcePid,p->initialThread,GetCurrentThreadId(),result,resourceMode,0,resourceProfile,0,
        diagnostics.status,diagnostics.firstFailure,diagnostics.storage,diagnostics.storageFailure};SetEvent(event);}
    ReleaseSRWLockExclusive(&resourceBridgeLock);CloseHandle(event);return result;
}
void BeamRT_ResourcePublishForBinding(const BeamRTBindingSnapshot& frame,DWORD thread,const BeamRTResourceDrawObservation* observation){
    const auto selectedProfile=resourceProfile.load();
    if(!observation || !beamrtResourceObservationValid(*observation,frame,thread,selectedProfile))return;
    const auto selectedMode=resourceMode.load();if(selectedMode==beamrtResourceDescriptorTextures && observation->cbvProbeBytes)return;
    BeamRTResourceCopyFailure copyFailure{};copyFailure.bytes=sizeof(copyFailure);copyFailure.abi=beamrtResourceCopyFailureABI;
    // The draw's immutable original cause is authoritative. Do not query a
    // future failure for a healthy/other-cause historical observation.
    if(beamrtResourceCopyFailureExpected(observation->firstFailure)){
        const auto queried=BeamRT_ResourcesCopyFailure(&copyFailure,sizeof(copyFailure));if(queried!=S_OK)return;
    }
    if(!beamrtResourceCopyFailureValid(copyFailure,observation->firstFailure,observation->status,selectedMode,selectedProfile)
        || (beamrtResourceCopyFailureExpected(observation->firstFailure)
            && std::memcmp(&copyFailure.storageFailure,&observation->storageFailure,sizeof(copyFailure.storageFailure))))return;
    // Never hold the bridge lock while querying tracker metadata. Both records
    // are joined to the same immutable original event before event publication.
    AcquireSRWLockExclusive(&resourceBridgeLock);
    if(resourceReply && !resourceRecorded){
        resourceReply->record={sizeof(BeamRTResourceRecordReceipt),beamrtResourceHandoffABI,resourcePid,thread,frame.serial,selectedMode,0,selectedProfile,0,*observation,copyFailure};
        resourceRecorded=true;
        // The binding bridge signals its existing record event only AFTER this
        // write. No separate polling flag or incoherent multi-write receipt.
    }
    ReleaseSRWLockExclusive(&resourceBridgeLock);
}
extern "C" HRESULT WINAPI BeamRT_ResourceRecordRead(BeamRTResourceRecordReceipt* out,uint32_t bytes){
    if(!out || bytes!=sizeof(*out))return E_INVALIDARG;*out={};AcquireSRWLockShared(&resourceBridgeLock);
    if(!resourceReply || !resourceRecorded){ReleaseSRWLockShared(&resourceBridgeLock);return HRESULT_FROM_WIN32(ERROR_NOT_READY);}
    *out=resourceReply->record;ReleaseSRWLockShared(&resourceBridgeLock);return S_OK;
}
