#include "gi_root_layout.h"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <vector>
#include <stdexcept>
#include <string>
int wmain(int argc,wchar_t** argv){try{
    if(argc==3 && std::wstring(argv[1])==L"--fixture-root-out"){
        D3D12_DESCRIPTOR_RANGE ranges[2]={{D3D12_DESCRIPTOR_RANGE_TYPE_SRV,6,0,0,0},{D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER,6,0,0,0}};
        D3D12_ROOT_PARAMETER params[3]{};params[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_CBV;params[0].Descriptor={0,0};
        for(UINT i=1;i<3;++i){params[i].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;params[i].DescriptorTable={1,&ranges[i-1]};}
        D3D12_ROOT_SIGNATURE_DESC desc{3,params,0,nullptr,D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT};
        Microsoft::WRL::ComPtr<ID3DBlob> blob,error;const auto serialized=D3D12SerializeRootSignature(&desc,D3D_ROOT_SIGNATURE_VERSION_1,&blob,&error);
        if(FAILED(serialized))throw std::runtime_error("fixture root serialization failed");
        HANDLE output=CreateFileW(argv[2],GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
        if(output==INVALID_HANDLE_VALUE)throw std::runtime_error("fixture output must be new");DWORD written=0;
        const auto ok=WriteFile(output,blob->GetBufferPointer(),static_cast<DWORD>(blob->GetBufferSize()),&written,nullptr);CloseHandle(output);
        if(!ok || written!=blob->GetBufferSize())throw std::runtime_error("fixture root write failed");
        std::cout<<"{\"fixture_owned\":true,\"bytes\":"<<written<<",\"game_capture\":false}\n";return 0;
    }
    if(argc!=2)throw std::runtime_error("root_inspect <existing serialized root file>");
    std::ifstream input(std::filesystem::path(argv[1]),std::ios::binary|std::ios::ate);
    if(!input || input.tellg()<=0 || input.tellg()>65536)throw std::runtime_error("root file missing/out of bounds");
    std::vector<uint8_t> bytes(static_cast<size_t>(input.tellg()));input.seekg(0);input.read(reinterpret_cast<char*>(bytes.data()),bytes.size());
    if(!input)throw std::runtime_error("root file truncated");BeamRTGIRootLayout layout;
    const auto result=beamrtDecodeGIRoot(bytes.data(),bytes.size(),layout);
    if(FAILED(result))throw std::runtime_error("SDK decoding/layout contract refused: "+std::to_string(result));
    std::cout<<"{\"bytes\":"<<bytes.size()<<",\"sdk_deserialized\":true,\"version\":\"1.0\",\"flags\":1,\"static_samplers\":0,"
        <<"\"cbv\":{\"parameter\":"<<layout.cbv<<",\"register\":0,\"space\":0},"
        <<"\"srv_table\":{\"parameter\":"<<layout.srv<<",\"first_register\":0,\"count\":6,\"space\":0,\"offset\":0},"
        <<"\"sampler_table\":{\"parameter\":"<<layout.sampler<<",\"first_register\":0,\"count\":6,\"space\":0,\"offset\":0},"
        <<"\"camera_verified\":false,\"resources_verified\":false,\"gpu_ordering_verified\":false}\n";return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
