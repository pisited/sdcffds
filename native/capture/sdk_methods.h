#pragma once
enum BeamRTMethod {
    CreateHeap,CreateSRV,CreateCBV,CreateUAV,CopySimple,CopyRanges,CreateRoot,CreateGraphics,
    CreateCompute,CreateList,ResetList,ClearList,SetHeaps,SetPipeline,SetGraphicsRoot,SetComputeRoot,
    SetGraphicsTable,SetComputeTable,Draw,DrawIndexed,Dispatch,Bundle,Indirect,ExecuteLists,MethodCount
};
#ifdef __cplusplus
extern "C"
#endif
void* beamrtSDKMethod(void* device,void* list,void* queue,unsigned method);
