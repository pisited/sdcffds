#pragma once
enum BeamRTMethod {
    CreateHeap,CreateSRV,CreateCBV,CreateUAV,CreateRTV,CopySimple,CopyRanges,CreateRoot,CreateGraphics,
    CreateCompute,CreateList,ResetList,ClearList,SetHeaps,SetPipeline,SetGraphicsRoot,SetComputeRoot,
    SetGraphicsTable,SetComputeTable,SetGraphicsConstant,SetComputeConstant,SetGraphicsConstants,SetComputeConstants,SetGraphicsCBV,SetComputeCBV,
    SetGraphicsUAV,SetComputeUAV,SetViewports,SetScissors,SetRenderTargets,ResourceBarrier,
    Draw,DrawIndexed,Dispatch,Bundle,Indirect,ExecuteLists,QueueSignal,QueueWait,MethodCount
};
#ifdef __cplusplus
extern "C"
#endif
void* beamrtSDKMethod(void* device,void* list,void* queue,unsigned method);
