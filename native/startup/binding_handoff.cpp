#define BEAMRT_BINDING_BUILD
#define BEAMRT_PIPELINE_AUDIT_BUILD
#include "binding_handoff.h"
#include "pipeline_audit.h"
#ifdef BEAMRT_RESOURCE_EMBEDDED
#include "resource_handoff.h"
#endif
#include <detours.h>
static SRWLOCK bridgeLock=SRWLOCK_INIT;
static BeamRTBindingReply* reply=nullptr;static HANDLE recordEvent=nullptr;
static bool attempted=false,recorded=false,targetAttempted=false;static DWORD pid=0;
static void progress(const BeamRTBindingStatus& s){if(!reply)return;auto& p=reply->progress;
    InterlockedExchange(&p.enabled,s.enabled);InterlockedExchange(&p.healthy,s.healthy);InterlockedExchange(&p.targetReady,s.targetReady);
    InterlockedExchange(&p.failureReason,s.failureReason);InterlockedExchange(&p.failureResult,s.failureResult);InterlockedExchange(&p.liveCommands,s.liveCommands);
    InterlockedExchange64(&p.creations,s.creations);InterlockedExchange64(&p.tagged,s.tagged);InterlockedExchange64(&p.pressureSkipped,s.pressureSkipped);
    InterlockedExchange64(&p.untracked,s.untracked);InterlockedExchange64(&p.matchedDraws,s.matchedDraws);InterlockedExchange64(&p.rejectedDraws,s.rejectedDraws);
    InterlockedExchange64(&p.unsupported,s.unsupported);InterlockedExchange64(&p.threadRejected,s.threadRejected);InterlockedExchange64(&p.serial,s.serial);
}
void BeamRT_BindingPublishProgress(const BeamRTBindingStatus& s){AcquireSRWLockExclusive(&bridgeLock);progress(s);ReleaseSRWLockExclusive(&bridgeLock);}
void BeamRT_BindingPublishThreadSample(const BeamRTBindingThreadSample& sample){
    AcquireSRWLockExclusive(&bridgeLock);
    if(reply && beamrtBindingThreadSampleValid(sample) && reply->threadSamples.count>=0 && reply->threadSamples.count<static_cast<LONG>(beamrtBindingThreadSampleLimit)){
        auto& out=reply->threadSamples;const auto count=out.count;out.samples[count]=sample;
        // Each slot is written once; publish only its completed immutable prefix.
        InterlockedExchange(&out.count,count+1);
    }
    ReleaseSRWLockExclusive(&bridgeLock);
}
void BeamRT_BindingPublishRecord(const BeamRTBindingStatus& s,const BeamRTBindingSnapshot& frame,DWORD thread,const BeamRTBindingThreadDiagnostics& diagnostics,const BeamRTResourceDrawObservation* resources){
#ifndef BEAMRT_RESOURCE_EMBEDDED
    (void)resources;
#endif
    AcquireSRWLockExclusive(&bridgeLock);progress(s);
    if(reply && !recorded && thread && s.enabled && s.healthy && s.targetReady && beamrtBindingSnapshotValid(frame)
        && beamrtBindingThreadDiagnosticsValid(diagnostics) && diagnostics.threadRejected==s.threadRejected){
        auto& out=reply->record;out.bytes=sizeof(out);out.abi=1;out.processId=pid;out.recordThread=thread;out.status=s;out.snapshot=frame;
        auto& threads=reply->threads;threads={sizeof(threads),beamrtBindingThreadABI,pid,thread,frame.serial,diagnostics};
#ifdef BEAMRT_RESOURCE_EMBEDDED
        BeamRT_ResourcePublishForBinding(frame,thread,resources);
#endif
        recorded=true;SetEvent(recordEvent);
    }
    ReleaseSRWLockExclusive(&bridgeLock);
}
void BeamRT_BindingBridgeAuditMatch(){
    AcquireSRWLockExclusive(&bridgeLock);
    const bool setup=reply && !targetAttempted;if(setup)targetAttempted=true;ReleaseSRWLockExclusive(&bridgeLock);if(!setup)return;
    // Verified first creation callback, after audit lock release. No bridge
    // lock is held while acquiring either observer's metadata lock.
    const auto result=BeamRT_BindingsVerifiedAuditMatch();BeamRTBindingStatus status{};BeamRT_BindingsStatus(&status,sizeof(status));
    AcquireSRWLockExclusive(&bridgeLock);progress(status);InterlockedExchange(&reply->progress.targetResult,result);
    InterlockedExchange(&reply->progress.targetThread,GetCurrentThreadId());InterlockedIncrement64(&reply->progress.targetAttempts);ReleaseSRWLockExclusive(&bridgeLock);
}
HRESULT BeamRT_BindingStartFromPayload(ID3D12Device* device){
    DWORD size=0;const auto p=static_cast<const BeamRTBindingPayload*>(DetourFindPayloadEx(beamrtBindingGuid,&size));if(!p)return S_FALSE;
    if(!beamrtBindingPayloadValid(p,size,GetCurrentProcessId(),GetCurrentThreadId()))return E_INVALIDARG;
    AcquireSRWLockExclusive(&bridgeLock);if(attempted){ReleaseSRWLockExclusive(&bridgeLock);return HRESULT_FROM_WIN32(ERROR_ALREADY_EXISTS);}
    attempted=true;pid=GetCurrentProcessId();const auto mapping=reinterpret_cast<HANDLE>(static_cast<ULONG_PTR>(p->outputMapping));
    reply=static_cast<BeamRTBindingReply*>(MapViewOfFile(mapping,FILE_MAP_WRITE,0,0,sizeof(BeamRTBindingReply)));CloseHandle(mapping);
    if(reply){reply->threadSamples.bytes=sizeof(reply->threadSamples);reply->threadSamples.abi=beamrtBindingThreadABI;reply->threadSamples.processId=pid;}
    recordEvent=reinterpret_cast<HANDLE>(static_cast<ULONG_PTR>(p->recordEvent));ReleaseSRWLockExclusive(&bridgeLock);
    const auto start=reinterpret_cast<HANDLE>(static_cast<ULONG_PTR>(p->startEvent));HRESULT result=E_INVALIDARG;BeamRTPipelineAuditInfo audit{};
    const auto queried=BeamRT_PipelineAuditQuery(&audit,sizeof(audit));
    if(reply && device && SUCCEEDED(queried) && audit.abi==beamrtPipelineAuditInfoABI && audit.enabled && audit.healthy && audit.ownerThread==p->initialThread){
#ifdef BEAMRT_RESOURCE_EMBEDDED
        BeamRT_ResourceStartFromPayload(device);
#endif
        result=BeamRT_BindingsStart(device);
    }
    BeamRTBindingStatus status{};BeamRT_BindingsStatus(&status,sizeof(status));
    if(reply){AcquireSRWLockExclusive(&bridgeLock);auto& out=reply->start;out.bytes=sizeof(out);out.abi=1;out.processId=pid;
        out.initialThread=p->initialThread;out.callerThread=GetCurrentThreadId();out.result=result;out.status=status;progress(status);SetEvent(start);ReleaseSRWLockExclusive(&bridgeLock);}
    CloseHandle(start);return result;
}
