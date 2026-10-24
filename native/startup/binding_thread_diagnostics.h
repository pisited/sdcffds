#pragma once
#include <cstdint>
inline constexpr uint32_t beamrtBindingThreadABI=1,beamrtBindingMethodCount=24,beamrtBindingThreadSampleLimit=16;
struct BeamRTBindingThreadSample {
    uint64_t commandId,generation;
    uint32_t method,expectedThread,callerThread,resetThread,firstRecordingThread;
    uint32_t targetReady,previouslyObservedTargetPipeline,metadataWasComplete,sourceWasSnapshot,reserved;
};
struct BeamRTBindingThreadDiagnostics {
    uint32_t bytes,abi,enabled,sampleCount;
    uint64_t threadRejected,firstEpochConflicts,repeatedCalls,beforeTarget,afterTarget,resetOwnerOnlyConflicts,droppedEpochSamples;
    uint64_t byMethod[beamrtBindingMethodCount];
    BeamRTBindingThreadSample samples[beamrtBindingThreadSampleLimit];
};
static_assert(sizeof(BeamRTBindingThreadSample)==56,"bounded CPU thread sample ABI");
static_assert(sizeof(BeamRTBindingThreadDiagnostics)==1160,"thread diagnostic ABI v1");
inline const char* beamrtBindingMethodName(uint32_t m){
    static const char* const names[]={"CreateCommandList","CreateCommandList1","Close","Reset","ClearState","SetPipelineState",
        "SetGraphicsRootSignature","SetDescriptorHeaps","SetGraphicsRootConstantBufferView","SetGraphicsRootDescriptorTable",
        "RSSetViewports","RSSetScissorRects","OMSetRenderTargets","DrawInstanced","DrawIndexedInstanced","ExecuteBundle",
        "ExecuteIndirect","BeginRenderPass","EndRenderPass","SetGraphicsRoot32BitConstant","SetGraphicsRoot32BitConstants",
        "SetGraphicsRootShaderResourceView","SetGraphicsRootUnorderedAccessView","SetPipelineState1"};
    return m<beamrtBindingMethodCount?names[m]:"invalid";
}
inline bool beamrtBindingThreadSampleValid(const BeamRTBindingThreadSample& s){
    return s.commandId && s.generation && s.method>=4 && s.method<beamrtBindingMethodCount && s.expectedThread && s.callerThread
        && s.expectedThread!=s.callerThread && (s.resetThread || s.firstRecordingThread)
        && (!s.resetThread || s.resetThread==s.expectedThread) && (!s.firstRecordingThread || s.firstRecordingThread==s.expectedThread)
        && s.targetReady<=1 && s.previouslyObservedTargetPipeline<=1 && (!s.previouslyObservedTargetPipeline || s.targetReady)
        && s.metadataWasComplete<=1 && s.sourceWasSnapshot<=1 && !s.reserved;
}
inline bool beamrtBindingThreadDiagnosticsValid(const BeamRTBindingThreadDiagnostics& d){
    if(d.bytes!=sizeof(d) || d.abi!=beamrtBindingThreadABI || d.enabled>1 || d.sampleCount>beamrtBindingThreadSampleLimit
        || d.firstEpochConflicts>d.threadRejected || d.repeatedCalls!=d.threadRejected-d.firstEpochConflicts
        || d.beforeTarget>d.threadRejected || d.afterTarget!=d.threadRejected-d.beforeTarget
        || d.resetOwnerOnlyConflicts>d.firstEpochConflicts || d.sampleCount>d.firstEpochConflicts
        || d.droppedEpochSamples!=d.firstEpochConflicts-d.sampleCount)return false;
    uint64_t sum=0;for(unsigned i=0;i<beamrtBindingMethodCount;++i){if(d.byMethod[i]>UINT64_MAX-sum)return false;sum+=d.byMethod[i];}
    if(sum!=d.threadRejected || d.byMethod[0] || d.byMethod[1] || d.byMethod[2] || d.byMethod[3])return false;
    for(unsigned i=0;i<d.sampleCount;++i){if(!beamrtBindingThreadSampleValid(d.samples[i]))return false;
        for(unsigned j=0;j<i;++j)if(d.samples[i].commandId==d.samples[j].commandId && d.samples[i].generation==d.samples[j].generation)return false;}
    return true;
}
