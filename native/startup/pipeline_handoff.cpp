#define BEAMRT_PIPELINE_AUDIT_BUILD
#include "pipeline_handoff.h"
#include <detours.h>
#include <cstring>
#ifdef BEAMRT_BINDING_EMBEDDED
#include "binding_handoff.h"
#endif
static SRWLOCK handoffLock=SRWLOCK_INIT;
static BeamRTPipelineReply* reply=nullptr;
static HANDLE matchEvent=nullptr;
static bool attempted=false,matched=false;
static DWORD processId=0;
void BeamRT_PipelinePublishProgress(const BeamRTPipelineAuditInfo& info){
    AcquireSRWLockExclusive(&handoffLock);
    if(reply){auto& p=reply->progress;InterlockedExchange64(&p.roots,static_cast<LONG64>(info.rootsObserved));
        InterlockedExchange64(&p.graphics,static_cast<LONG64>(info.graphicsObserved));InterlockedExchange64(&p.streams,static_cast<LONG64>(info.unsupportedStreams));
        InterlockedExchange64(&p.shaderMatches,static_cast<LONG64>(info.shaderMatches));InterlockedExchange64(&p.unknownRoots,static_cast<LONG64>(info.unknownRootMatches));
        InterlockedExchange(&p.failureResult,info.failureResult);InterlockedExchange(&p.failureReason,static_cast<LONG>(info.failureReason));
        InterlockedExchange(&p.cachedLayouts,static_cast<LONG>(info.cachedLayouts));InterlockedExchange(&p.liveLayouts,static_cast<LONG>(info.liveLayouts));
        InterlockedExchange(&p.liveRootTags,static_cast<LONG>(info.liveRootTags));InterlockedExchange64(&p.rootsTagged,static_cast<LONG64>(info.rootsTagged));
        InterlockedExchange64(&p.budgetSkipped,static_cast<LONG64>(info.budgetSkipped));InterlockedExchange64(&p.cacheEvictions,static_cast<LONG64>(info.cacheEvictions));
        InterlockedExchange64(&p.metadataBytes,static_cast<LONG64>(info.metadataBytes));InterlockedExchange64(&p.peakMetadataBytes,static_cast<LONG64>(info.peakMetadataBytes));
        InterlockedExchange(&p.healthy,static_cast<LONG>(info.healthy));InterlockedExchange(&p.enabled,static_cast<LONG>(info.enabled));}
    ReleaseSRWLockExclusive(&handoffLock);
}
void BeamRT_PipelinePublishMatch(const BeamRTPipelineAuditInfo& info,const void* root,uint32_t bytes){
    AcquireSRWLockExclusive(&handoffLock);
    if(reply && !matched && root && bytes && bytes<=sizeof(reply->match.root)){
        auto& out=reply->match;out.bytes=sizeof(out);out.abi=beamrtPipelineHandoffABI;out.processId=processId;out.rootBytes=bytes;out.info=info;
        std::memcpy(out.root,root,bytes);matched=true;SetEvent(matchEvent);
    }
    ReleaseSRWLockExclusive(&handoffLock);
}
HRESULT BeamRT_PipelineStartFromPayload(ID3D12Device* device,const void* caller){
    DWORD bytes=0;const auto p=static_cast<const BeamRTPipelinePayload*>(DetourFindPayloadEx(beamrtPipelineGuid,&bytes));
    if(!p)return S_FALSE;if(!beamrtPipelinePayloadValid(p,bytes,GetCurrentProcessId()))return E_INVALIDARG;
    AcquireSRWLockExclusive(&handoffLock);
    if(attempted){ReleaseSRWLockExclusive(&handoffLock);return HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS);}
    attempted=true;processId=GetCurrentProcessId();
    const auto output=reinterpret_cast<HANDLE>(static_cast<ULONG_PTR>(p->outputMapping));
    reply=static_cast<BeamRTPipelineReply*>(MapViewOfFile(output,FILE_MAP_WRITE,0,0,sizeof(BeamRTPipelineReply)));CloseHandle(output);
    matchEvent=reinterpret_cast<HANDLE>(static_cast<ULONG_PTR>(p->matchEvent));
    ReleaseSRWLockExclusive(&handoffLock);
    const auto start=reinterpret_cast<HANDLE>(static_cast<ULONG_PTR>(p->startEvent));
    const auto input=reinterpret_cast<HANDLE>(static_cast<ULONG_PTR>(p->inputMapping));
    const SIZE_T size=sizeof(BeamRTPipelineInput)+SIZE_T(p->vertexBytes)+p->pixelBytes;
    const auto view=static_cast<const uint8_t*>(MapViewOfFile(input,FILE_MAP_READ,0,0,size));CloseHandle(input);
    HRESULT result=E_INVALIDARG;MEMORY_BASIC_INFORMATION memory{};
    if(reply && view && device && GetCurrentThreadId()==p->initialThread && caller
        && VirtualQuery(caller,&memory,sizeof(memory)) && memory.AllocationBase==GetModuleHandleW(nullptr)
        && memory.Type==MEM_IMAGE && memory.State==MEM_COMMIT && !(memory.Protect&(PAGE_GUARD|PAGE_NOACCESS))
        && (memory.Protect&(PAGE_EXECUTE_READ|PAGE_EXECUTE_READWRITE|PAGE_EXECUTE_WRITECOPY))){
        const auto header=reinterpret_cast<const BeamRTPipelineInput*>(view);
        if(header->bytes==sizeof(*header) && header->abi==1 && header->vertexBytes==p->vertexBytes && header->pixelBytes==p->pixelBytes){
            BeamRTPipelineAuditConfig config{sizeof(config),1,view+sizeof(*header),p->vertexBytes,
                view+sizeof(*header)+p->vertexBytes,p->pixelBytes,{0,0}};
            result=BeamRT_PipelineAuditStart(device,&config);
#ifdef BEAMRT_BINDING_EMBEDDED
            if(SUCCEEDED(result))BeamRT_BindingStartFromPayload(device);
#endif
        }
    }
    if(view)UnmapViewOfFile(view);
    if(reply){auto& out=reply->start;out.bytes=sizeof(out);out.abi=beamrtPipelineHandoffABI;out.processId=processId;
        out.initialThread=p->initialThread;out.callerThread=GetCurrentThreadId();out.result=result;
        BeamRT_PipelineAuditQuery(&out.info,sizeof(out.info));BeamRT_PipelinePublishProgress(out.info);SetEvent(start);}
    CloseHandle(start);
    // Reply/match-event lifetime is process-bound. No thread, file logging,
    // GPU commands or remote function invocation. Start/match regions never
    // get rewritten, including when a later device/metadata becomes invalid.
    return result;
}
