// Isolated test fixture only. Included after self_test.cpp's SDK helpers.
#pragma once
#include <array>
#include <chrono>
#include <condition_variable>
#include <future>
#include <memory>
#include <mutex>

struct MultiQueuePass {
    Renderer renderer;
    ComPtr<ID3D12DescriptorHeap> cpu,gpu,rtv;
    ComPtr<ID3D12RootSignature> root;
    ComPtr<ID3D12PipelineState> pipeline;
    ComPtr<ID3D12Resource> target,readback;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
    UINT stride=0;
    UINT64 total=0;

    D3D12_CPU_DESCRIPTOR_HANDLE address(ID3D12DescriptorHeap* heap,UINT index) const {
        auto handle=heap->GetCPUDescriptorHandleForHeapStart();
        handle.ptr+=SIZE_T(index)*stride;return handle;
    }
    void writeFirst(ID3D12Resource* resource) {
        D3D12_SHADER_RESOURCE_VIEW_DESC view{};
        view.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;
        view.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;
        view.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        view.Texture2D.MipLevels=1;
        renderer.device->CreateShaderResourceView(resource,&view,address(cpu.Get(),0));
        renderer.device->CopyDescriptorsSimple(1,address(gpu.Get(),0),address(cpu.Get(),0),D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    }
    MultiQueuePass(ID3D12Device* device,const BeamRTCaptureConfig& config,
                   const std::vector<uint8_t>& vs,ID3D12Resource* first,
                   ID3D12Resource* second,ID3D12Resource* lights):renderer(device) {
        D3D12_DESCRIPTOR_HEAP_DESC heap{};
        heap.Type=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;heap.NumDescriptors=3;
        hr(device->CreateDescriptorHeap(&heap,IID_PPV_ARGS(&cpu)));
        heap.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        hr(device->CreateDescriptorHeap(&heap,IID_PPV_ARGS(&gpu)));
        stride=device->GetDescriptorHandleIncrementSize(heap.Type);
        writeFirst(first);
        D3D12_SHADER_RESOURCE_VIEW_DESC view{};
        view.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;
        view.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;
        view.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        view.Texture2D.MipLevels=1;
        device->CreateShaderResourceView(second,&view,address(cpu.Get(),1));
        view={};view.ViewDimension=D3D12_SRV_DIMENSION_BUFFER;
        view.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        view.Buffer={0,1,16,D3D12_BUFFER_SRV_FLAG_NONE};
        device->CreateShaderResourceView(lights,&view,address(cpu.Get(),2));
        device->CopyDescriptorsSimple(2,address(gpu.Get(),1),address(cpu.Get(),1),heap.Type);
        hr(device->CreateRootSignature(0,config.rootSignature,static_cast<SIZE_T>(config.rootSignatureBytes),IID_PPV_ARGS(&root)));
        D3D12_GRAPHICS_PIPELINE_STATE_DESC pso{};
        pso.pRootSignature=root.Get();pso.VS={vs.data(),vs.size()};
        pso.PS={config.shader,static_cast<SIZE_T>(config.shaderBytes)};
        pso.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;
        pso.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;
        pso.RasterizerState.DepthClipEnable=TRUE;
        pso.BlendState.RenderTarget[0].RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;
        pso.SampleMask=UINT_MAX;pso.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
        pso.NumRenderTargets=1;pso.RTVFormats[0]=DXGI_FORMAT_R32G32B32A32_FLOAT;
        pso.SampleDesc.Count=1;
        hr(device->CreateGraphicsPipelineState(&pso,IID_PPV_ARGS(&pipeline)));
        D3D12_RESOURCE_DESC desc{};desc.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        desc.Width=1;desc.Height=1;desc.DepthOrArraySize=1;desc.MipLevels=1;
        desc.SampleDesc.Count=1;desc.Format=DXGI_FORMAT_R32G32B32A32_FLOAT;
        desc.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
        target=make(device,desc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_RENDER_TARGET);
        D3D12_DESCRIPTOR_HEAP_DESC rt{};rt.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;rt.NumDescriptors=1;
        hr(device->CreateDescriptorHeap(&rt,IID_PPV_ARGS(&rtv)));
        device->CreateRenderTargetView(target.Get(),nullptr,rtv->GetCPUDescriptorHandleForHeapStart());
        UINT rows;UINT64 rowBytes;
        device->GetCopyableFootprints(&desc,0,1,0,&footprint,&rows,&rowBytes,&total);
        readback=make(device,buffer(total),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
    }
    void draw(float expected) {
        renderer.begin();auto list=renderer.list.Get();
        list->SetPipelineState(pipeline.Get());list->SetGraphicsRootSignature(root.Get());
        ID3D12DescriptorHeap* heaps[]={gpu.Get()};list->SetDescriptorHeaps(1,heaps);
        list->SetGraphicsRootDescriptorTable(0,gpu->GetGPUDescriptorHandleForHeapStart());
        const D3D12_VIEWPORT viewport{0,0,1,1,0,1};const D3D12_RECT scissor{0,0,1,1};
        list->RSSetViewports(1,&viewport);list->RSSetScissorRects(1,&scissor);
        auto rt=rtv->GetCPUDescriptorHandleForHeapStart();list->OMSetRenderTargets(1,&rt,FALSE,nullptr);
        list->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        list->DrawInstanced(3,1,0,0);
        transition(list,target.Get(),D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE);
        D3D12_TEXTURE_COPY_LOCATION dst{},src{};
        dst.pResource=readback.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=footprint;
        src.pResource=target.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        list->CopyTextureRegion(&dst,0,0,0,&src,nullptr);
        transition(list,target.Get(),D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_RENDER_TARGET);
        renderer.submit();
        void* mapped;D3D12_RANGE range{0,static_cast<SIZE_T>(total)},none{0,0};
        hr(readback->Map(0,&range,&mapped));
        const float pixel=*reinterpret_cast<const float*>(static_cast<const uint8_t*>(mapped)+footprint.Offset);
        readback->Unmap(0,&none);
        require(std::abs(pixel-expected)<.00001f,"multithread capture changed normal GPU output");
    }
};
struct QueueSnapshotOwner {
    BeamRTCaptureSnapshot* value=nullptr;
    QueueSnapshotOwner()=default;
    QueueSnapshotOwner(const QueueSnapshotOwner&)=delete;
    QueueSnapshotOwner& operator=(const QueueSnapshotOwner&)=delete;
    ~QueueSnapshotOwner(){BeamRT_CaptureReleaseSnapshot(&value);}
};

static void testMultithreadCapture(BeamRTCapture*& host,ID3D12Device* device,
    const BeamRTCaptureConfig& original,const std::vector<uint8_t>& vs,
    ID3D12Resource* first,ID3D12Resource* second,ID3D12Resource* alternate,ID3D12Resource* lights) {
    auto config=original;config.threadMode=BEAMRT_CAPTURE_MULTITHREAD;
    success(BeamRT_CaptureStart(device,&config,1,&host));
    // Workers start AFTER installation and finish BEFORE detachment. The test
    // establishes real quiescence; no guessed thread suspension/loading policy.
    std::mutex gateMutex;std::condition_variable gate;unsigned ready=0;
    std::array<DWORD,2> threads{};
    std::array<std::future<std::unique_ptr<MultiQueuePass>>,2> jobs;
    for(UINT i=0;i<2;++i)jobs[i]=std::async(std::launch::async,[&,i]{
        threads[i]=GetCurrentThreadId();
        {
            std::unique_lock<std::mutex> lock(gateMutex);++ready;gate.notify_all();
            require(gate.wait_for(lock,std::chrono::seconds(10),[&]{return ready==2;}),"test thread startup timed out");
        }
        auto pass=std::make_unique<MultiQueuePass>(device,config,vs,i==0?first:alternate,second,lights);
        pass->draw(i==0?3.75f:6.75f);return pass;
    });
    std::array<std::unique_ptr<MultiQueuePass>,2> passes;
    for(UINT i=0;i<2;++i)passes[i]=jobs[i].get();
    require(threads[0]!=threads[1] && threads[0]!=GetCurrentThreadId()
            && threads[1]!=GetCurrentThreadId(),"fixture did not use independent API threads");
    BeamRTCaptureStatus status{};success(BeamRT_CaptureGetStatus(host,&status));
    require(status.captureHealthy && status.capturedSubmissions==2 && status.queueCount==2
            && status.threadMode==BEAMRT_CAPTURE_MULTITHREAD,"concurrent capture lost queue submissions");
    std::array<QueueSnapshotOwner,2> snapshots;
    std::array<BeamRTCaptureInfo,2> info{};
    for(UINT i=0;i<2;++i){
        success(BeamRT_CaptureGetSnapshotForQueue(host,passes[i]->renderer.queue.Get(),&snapshots[i].value));
        success(BeamRT_CaptureReadSnapshot(snapshots[i].value,&info[i]));
        require(info[i].queue==passes[i]->renderer.queue.Get()
                && info[i].resources[0]==(i==0?first:alternate)
                && info[i].resources[1]==second && info[i].resources[2]==lights,
                "queue-specific capture mixed independent resources");
        require(!info[i].cameraVerified && !info[i].gpuOrderingVerified && !info[i].lightingConsumed,
                "multithread capture incorrectly certified game integration");
    }
    require(info[0].submission!=info[1].submission,"CPU submission serial was not unique");
    D3D12_COMMAND_QUEUE_DESC q{};q.Type=D3D12_COMMAND_LIST_TYPE_DIRECT;
    ComPtr<ID3D12CommandQueue> unseen;hr(device->CreateCommandQueue(&q,IID_PPV_ARGS(&unseen)));
    QueueSnapshotOwner missing;
    require(BeamRT_CaptureGetSnapshotForQueue(host,unseen.Get(),&missing.value)!=0
            && !missing.value,"unseen queue borrowed another queue snapshot");
    // Invalidating one queue must not erase or borrow the other queue's result.
    passes[0]->writeFirst(nullptr);passes[0]->draw(2.75f);
    require(BeamRT_CaptureGetSnapshotForQueue(host,passes[0]->renderer.queue.Get(),&missing.value)!=0
            && !missing.value,"invalid queue retained stale descriptor provenance");
    QueueSnapshotOwner unaffected;
    success(BeamRT_CaptureGetSnapshotForQueue(host,passes[1]->renderer.queue.Get(),&unaffected.value));
    BeamRTCaptureInfo still{};success(BeamRT_CaptureReadSnapshot(unaffected.value,&still));
    require(still.submission==info[1].submission && still.resources[0]==alternate,
            "one invalid queue changed the other queue's capture");
    // Sequential handoff of a list from a finished worker to this thread is
    // legal; simultaneous recording of the same list would not be supported.
    passes[0]->writeFirst(first);passes[0]->draw(3.75f);
    QueueSnapshotOwner restored;
    success(BeamRT_CaptureGetSnapshotForQueue(host,passes[0]->renderer.queue.Get(),&restored.value));
    BeamRTCaptureInfo recovered{};success(BeamRT_CaptureReadSnapshot(restored.value,&recovered));
    require(recovered.resources[0]==first && recovered.recordingGeneration>info[0].recordingGeneration,
            "cross-thread sequential list reset did not recover");
    auto wrongThread=std::async(std::launch::async,[&]{
        BeamRTCapture* alias=host;return BeamRT_CaptureStop(&alias,1)!=0 && alias==host;
    });
    require(wrongThread.get(),"another control thread detached the capture hooks");
    require(BeamRT_CaptureStop(&host,0)!=0 && host,"multithread unsafe detach accepted");
    success(BeamRT_CaptureStop(&host,1));
    passes[0]->draw(3.75f);passes[1]->draw(6.75f);
    for(auto& pass:passes)pass.reset();
    for(UINT i=0;i<2;++i){
        BeamRTCaptureInfo retained{};success(BeamRT_CaptureReadSnapshot(snapshots[i].value,&retained));
        require(retained.queue->GetDesc().Type==D3D12_COMMAND_LIST_TYPE_DIRECT
                && retained.resources[0]->GetDesc().Width==1,"queue snapshot ownership did not survive detach");
    }
    std::cout<<"PASS: two concurrent API threads/queues, isolated queue provenance, sequential list handoff, queue snapshot lifetime and unchanged GPU output\n";
}
