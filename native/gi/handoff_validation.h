#pragma once
// OFFLINE fixture contract only. Not an automatic capture-to-GI converter,
// camera decoder, game-state tracker or replacement for GI frame retirement.
#include "beamrt_gi.h"
#include "../capture/beamrt_capture.h"
#include "shader_contract.h"
#include <windows.h>
#include <wrl/client.h>
#include <cmath>
#include <cstring>
#include <stdexcept>
#include <string>

namespace beamrt_fixture {
using Microsoft::WRL::ComPtr;
struct InitialState {
    ID3D12Resource* resource=nullptr;
    uint32_t state=0,known=0;
};
struct HandoffEvidence {
    ID3D12Device* device=nullptr;
    ID3D12CommandQueue* queue=nullptr;
    ID3D12Fence* fence=nullptr;
    ID3D12Resource* output=nullptr;
    DWORD ownerThread=0;
    uint32_t fixtureSidecarProvided=0,exclusiveSerializedQueue=0,unchangedAfterProducerDraw=0;
    uint64_t submission=0,recordingGeneration=0,executionSerial=0,eventSerial=0;
    uint64_t producerValue=0,computeValue=0,consumerValue=0;
    InitialState initial[3]{}; // receiver, packed mesh, diagnostic producer RTV
    float expectedKey[4]{}; // independent current fixture generation contract
    BeamRTGIInputs sidecar{}; // supplied by fixture, NOT inferred from capture
    const ShaderContract* layout=nullptr;
    const std::vector<KnownConstantBuffer>* constantBuffers=nullptr;
    float expectedControl[4]{}; // verified fixture fields, NOT a camera matrix
};
struct ConsumerReceipt {
    ID3D12CommandQueue* queue=nullptr;
    ID3D12Fence* fence=nullptr;
    uint64_t computeValue=0,consumerValue=0;
    uint64_t submission=0,recordingGeneration=0;
    float key[4]{};
    uint32_t finalConsumerSubmitted=0;
};
inline D3D12_RESOURCE_DESC fullTexture(ID3D12Device* device,ID3D12Resource* resource,
    DXGI_FORMAT format,uint32_t width,uint32_t height) {
    owned(device,resource);const auto d=resource->GetDesc();
    demand(d.Dimension==D3D12_RESOURCE_DIMENSION_TEXTURE2D && d.Format==format
        && d.Width==width && d.Height==height && d.DepthOrArraySize==1 && d.MipLevels==1
        && d.SampleDesc.Count==1 && d.SampleDesc.Quality==0
        && !(d.Flags&(D3D12_RESOURCE_FLAG_ALLOW_SIMULTANEOUS_ACCESS|D3D12_RESOURCE_FLAG_DENY_SHADER_RESOURCE)),
        "unsupported texture format/dimensions/view");
    D3D12_HEAP_PROPERTIES heap{};D3D12_HEAP_FLAGS flags{};
    demand(SUCCEEDED(resource->GetHeapProperties(&heap,&flags)) && heap.Type==D3D12_HEAP_TYPE_DEFAULT,
           "default GPU texture required");
    return d;
}
inline void fullSrv(const D3D12_SHADER_RESOURCE_VIEW_DESC& view,DXGI_FORMAT format) {
    demand(view.Format==format && view.ViewDimension==D3D12_SRV_DIMENSION_TEXTURE2D
        && view.Shader4ComponentMapping==D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING
        && view.Texture2D.MostDetailedMip==0 && view.Texture2D.MipLevels==1
        && view.Texture2D.PlaneSlice==0 && view.Texture2D.ResourceMinLODClamp==0,
        "unsupported SRV range/component mapping");
}
inline void hostContract(const HandoffEvidence& e) {
    demand(e.fixtureSidecarProvided==1 && e.exclusiveSerializedQueue==1 && e.unchangedAfterProducerDraw==1
        && e.ownerThread==GetCurrentThreadId(),"missing exclusive offline fixture context");
    demand(e.device && SUCCEEDED(e.device->GetDeviceRemovedReason()),"missing/removed fixture device");
    owned(e.device,e.queue);owned(e.device,e.fence);
    demand(e.queue->GetDesc().Type==D3D12_COMMAND_LIST_TYPE_DIRECT,"same DIRECT queue required");
    demand(e.submission && e.recordingGeneration && e.executionSerial && e.eventSerial,
           "missing expected snapshot generation");
    demand(e.producerValue>0 && e.producerValue<UINT64_MAX-2
        && e.computeValue==e.producerValue+1 && e.consumerValue==e.computeValue+1,
        "invalid producer/compute/final-consumer fence schedule");
}
inline void sidecarContract(const BeamRTGIInputs& p) {
    demand(p.width>0 && p.width<=2048 && p.height>0 && p.height<2048 && p.reserved==0
        && p.surfelCount>0 && p.surfelCount<=32 && uint64_t(p.width)*p.height*p.surfelCount<=1048576,
        "unsupported GI dimensions/surfel budget");
    for(float key:p.key)demand(std::isfinite(key) && key>=1 && key<=16777215 && std::floor(key)==key,
                               "missing/stale generation key");
    demand(p.key[3]==1,"unknown visibility layout key");
    for(UINT i=0;i<p.surfelCount;++i){
        for(float value:p.surfels[i])demand(std::isfinite(value),"nonfinite fixture surfel");
        demand(p.surfels[i][3]>0,"invalid fixture surfel radius");
    }
    const auto& s=p.scene;
    demand(s.atlas[0]>0 && s.atlas[0]<=16384 && s.atlas[1]>0 && s.atlas[1]<=16384
        && s.counts[0]>0 && s.counts[0]<=4096 && s.counts[1]>0 && s.counts[1]<=200000
        && s.counts[2]==2+6*s.counts[0]
        && uint64_t(s.counts[2])+uint64_t(s.counts[1])*7<=uint64_t(s.atlas[0])*s.atlas[1]
        && !s.counts[3] && !s.atlas[2] && !s.atlas[3],"invalid explicit scene layout");
    const float* vectors[]={s.origin,s.inverseX,s.inverseY,s.inverseZ,s.quantMin,s.quantExtent};
    for(auto vector:vectors)for(int i=0;i<4;++i)demand(std::isfinite(vector[i]),"nonfinite fixture transform");
    for(int i=0;i<3;++i)demand(s.quantExtent[i]>0,"invalid fixture quantization extent");
    const auto& x=s.inverseX;const auto& y=s.inverseY;const auto& z=s.inverseZ;
    const float det=x[0]*(y[1]*z[2]-y[2]*z[1])-x[1]*(y[0]*z[2]-y[2]*z[0])+x[2]*(y[0]*z[1]-y[1]*z[0]);
    demand(std::isfinite(det) && std::abs(det)>1e-10f,"singular fixture transform");
    for(auto mode:s.materials)demand(mode<=3,"invalid explicit material policy");
}
inline bool supportedState(uint32_t state) {
    return state==D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE
        || state==D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE
        || state==static_cast<uint32_t>(D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE|D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE)
        || state==D3D12_RESOURCE_STATE_COPY_SOURCE || state==D3D12_RESOURCE_STATE_RENDER_TARGET;
}
inline void validateInputsOrThrow(const BeamRTCaptureInfo& info,const HandoffEvidence& e,BeamRTGIInputs& out) {
    hostContract(e);sidecarContract(e.sidecar);
    for(int i=0;i<4;++i)demand(e.sidecar.key[i]==e.expectedKey[i],"sidecar generation does not match current fixture");
    demand(info.kind==1 && info.count==2 && info.contextComplete==1,"incomplete/unsupported producer context");
    demand(info.submission==e.submission && info.recordingGeneration==e.recordingGeneration
        && info.queueExecutionSerial==e.executionSerial && info.queueEventSerial==e.eventSerial,
        "stale or unexpected producer snapshot");
    demand(sameObject(info.queue,e.queue),"producer queue mismatch");
    demand(!info.cameraVerified && !info.gpuOrderingVerified && !info.resourceStateChainVerified && !info.lightingConsumed,
           "raw capture improperly claims semantic verification");
    demand(e.layout && e.layout->role()==PassRole::Producer && e.constantBuffers,"missing verified producer manifest/buffer registry");
    ResolvedConstants constants;std::string bindingReason;
    const bool resolved=resolveConstants(e.device,info,*e.layout,*e.constantBuffers,e.expectedKey,constants,bindingReason);
    demand(resolved,bindingReason.c_str());
    const auto field=e.layout->field("fixtureControl");float values[4]{};
    std::memcpy(values,constants.contents.data()+field.offset,sizeof(values));
    for(int i=0;i<4;++i)demand(std::isfinite(values[i]) && values[i]==e.expectedControl[i],
                              "constant contents do not match fixture semantics");
    demand(sameObject(info.resources[0],static_cast<ID3D12Resource*>(e.sidecar.receivers))
        && sameObject(info.resources[1],static_cast<ID3D12Resource*>(e.sidecar.mesh)),"SRV resource-role mismatch");
    fullSrv(info.views[0],DXGI_FORMAT_R32G32B32A32_FLOAT);fullSrv(info.views[1],DXGI_FORMAT_R8G8B8A8_UNORM);
    fullTexture(e.device,info.resources[0],DXGI_FORMAT_R32G32B32A32_FLOAT,e.sidecar.width,e.sidecar.height);
    fullTexture(e.device,info.resources[1],DXGI_FORMAT_R8G8B8A8_UNORM,e.sidecar.scene.atlas[0],e.sidecar.scene.atlas[1]);
    demand(info.renderTargetCount==1 && sameObject(info.renderTargets[0],e.output)
        && info.renderTargetFormats[0]==DXGI_FORMAT_R32G32B32A32_FLOAT,"producer output identity/format mismatch");
    const auto target=fullTexture(e.device,e.output,DXGI_FORMAT_R32G32B32A32_FLOAT,e.sidecar.width,e.sidecar.height);
    demand((target.Flags&D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET)!=0,"producer output is not an RTV");
    demand(info.viewportCount==1 && info.scissorCount==1,"missing/unsupported viewport or scissor");
    const auto& v=info.viewports[0];const auto& r=info.scissors[0];
    demand(v.TopLeftX==0 && v.TopLeftY==0 && v.Width==static_cast<float>(e.sidecar.width)
        && v.Height==static_cast<float>(e.sidecar.height) && v.MinDepth==0 && v.MaxDepth==1
        && r.left==0 && r.top==0 && r.right==static_cast<LONG>(e.sidecar.width)
        && r.bottom==static_cast<LONG>(e.sidecar.height),"viewport/output coverage mismatch");
    ID3D12Resource* roles[]={info.resources[0],info.resources[1],e.output};
    demand(!sameObject(roles[0],roles[1]) && !sameObject(roles[0],roles[2]) && !sameObject(roles[1],roles[2]),
           "input/output resource roles alias");
    uint32_t states[3]{},seen[3]{};
    for(UINT i=0;i<3;++i){
        demand(e.initial[i].known==1 && sameObject(e.initial[i].resource,roles[i])
            && supportedState(e.initial[i].state),"missing/unsupported explicit starting state");
        states[i]=e.initial[i].state;
    }
    demand(info.transitionCount>0 && info.transitionCount<=BEAMRT_CAPTURE_MAX_TRANSITIONS,
           "missing/overflowed transition evidence");
    for(UINT n=0;n<info.transitionCount;++n){
        const auto& t=info.transitions[n];
        demand(t.subresource==D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,"partial-subresource transition unsupported");
        UINT role=0;while(role<3 && !sameObject(t.resource,roles[role]))++role;
        demand(role<3,"transition resource has no explicit starting state");
        demand(t.before==states[role] && t.before!=t.after && supportedState(t.after),"broken/unsupported transition chain");
        const uint32_t terminal=role==2?D3D12_RESOURCE_STATE_RENDER_TARGET:D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;
        demand(seen[role]<2 && t.after==(seen[role]==0?D3D12_RESOURCE_STATE_COPY_SOURCE:terminal),
               "transition is outside the known fixture program");
        states[role]=t.after;++seen[role];
    }
    demand(seen[0]==2 && seen[1]==2 && seen[2]==2,"incomplete controlled-fixture transition coverage");
    demand(states[0]==D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE
        && states[1]==D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE
        && states[2]==D3D12_RESOURCE_STATE_RENDER_TARGET,"resource states incompatible with producer draw");
    demand(e.sidecar.receiverState==states[0] && e.sidecar.meshState==states[1],"sidecar state disagrees with observed chain");
    demand(sameObject(info.queueSignalFence,e.fence) && info.queueSignalValue==e.producerValue
        && !info.queueWaitFence && info.queueWaitValue==0,"unexpected producer fence/cross-queue wait");
    const UINT64 done=e.fence->GetCompletedValue();
    demand(done!=UINT64_MAX && done>=e.producerValue,"producer completion not established");
    out=e.sidecar;out.receivers=info.resources[0];out.mesh=info.resources[1];
    out.receiverState=states[0];out.meshState=states[1];
}
inline bool validateInputs(const BeamRTCaptureInfo& info,const HandoffEvidence& e,
    BeamRTGIInputs& out,std::string& reason) {
    out={};reason.clear();
    try{BeamRTGIInputs pending{};validateInputsOrThrow(info,e,pending);out=pending;return true;}
    catch(const std::exception& error){reason=error.what();return false;}
}
inline bool validateConsumerCompletion(const HandoffEvidence& e,const ConsumerReceipt& receipt,std::string& reason) {
    reason.clear();
    try {
        hostContract(e);
        demand(receipt.submission==e.submission && receipt.recordingGeneration==e.recordingGeneration,
               "consumer receipt belongs to another recording");
        for(int i=0;i<4;++i)demand(receipt.key[i]==e.expectedKey[i] && e.sidecar.key[i]==e.expectedKey[i],
                                  "consumer receipt generation mismatch");
        demand(sameObject(receipt.queue,e.queue) && sameObject(receipt.fence,e.fence),"consumer queue/fence mismatch");
        demand(receipt.finalConsumerSubmitted==1 && receipt.computeValue==e.computeValue
            && receipt.consumerValue==e.consumerValue && receipt.consumerValue>receipt.computeValue,
            "missing/stale final-consumer submission receipt");
        const UINT64 done=e.fence->GetCompletedValue();
        demand(done!=UINT64_MAX && done>=receipt.consumerValue,"final-consumer fence has not completed");
        return true;
    } catch(const std::exception& error){reason=error.what();return false;}
}
} // namespace beamrt_fixture
