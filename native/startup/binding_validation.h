#pragma once
#include "gi_bindings.h"
inline bool beamrtBindingTable(uint64_t address,const BeamRTBindingHeap& h,uint64_t* cpu){
    if(!h.gpu || !h.cpu || !h.stride || h.count<6 || address<h.gpu || (address-h.gpu)%h.stride)return false;
    const auto index=(address-h.gpu)/h.stride;if(index>uint64_t(h.count)-6)return false;
    for(uint64_t i=0;i<6;++i){const auto offset=(index+i)*h.stride;if(offset>UINT64_MAX-h.cpu)return false;cpu[i]=h.cpu+offset;}return true;
}
