#include "fixture_contract.h"
#include <shellapi.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <filesystem>
#include <fstream>
#include <vector>
#include <string>
#include <cstring>
#include <bcrypt.h>
using Microsoft::WRL::ComPtr;
using Query=HRESULT(WINAPI*)(BeamRTPipelineAuditInfo*,uint32_t);
using Read=HRESULT(WINAPI*)(void*,uint32_t,uint32_t*,ID3D12RootSignature**,ID3D12PipelineState**);
using Disable=HRESULT(WINAPI*)();
static std::vector<uint8_t> file(const std::wstring& path){std::ifstream input(std::filesystem::path(path),std::ios::binary|std::ios::ate);
    if(!input || input.tellg()<=0 || input.tellg()>16*1024*1024)return {};std::vector<uint8_t> bytes(static_cast<size_t>(input.tellg()));
    input.seekg(0);input.read(reinterpret_cast<char*>(bytes.data()),static_cast<std::streamsize>(bytes.size()));return input?bytes:std::vector<uint8_t>{};}
static bool writeNew(const std::wstring& path,const void* data,DWORD bytes){
    HANDLE output=CreateFileW(path.c_str(),GENERIC_WRITE,FILE_SHARE_READ,nullptr,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,nullptr);
    if(output==INVALID_HANDLE_VALUE)return false;DWORD written=0;const BOOL ok=WriteFile(output,data,bytes,&written,nullptr);CloseHandle(output);return ok && written==bytes;
}
int WINAPI wWinMain(HINSTANCE,HINSTANCE,LPWSTR,int){
    int count=0;auto values=CommandLineToArgvW(GetCommandLineW(),&count);if(!values)return 80;
    std::vector<std::wstring> args(values,values+count);LocalFree(values);
    const bool conflict=args.size()>7 && args[7]==L"--root-conflict";if(conflict)args.erase(args.begin()+7);
    if(args.size()!=22 || args[1]!=L"--device-backend" || args[3]!=L"--vs" || args[5]!=L"--ps" || args[7]!=L"--report"
        || args[9]!=L"--module" || args[11]!=L"--hold-ms" || args[13]!=L"--exit-code" || args[15]!=L"--")return 80;
    const auto vs=file(args[4]),ps=file(args[6]);if(vs.empty() || ps.empty())return 81;
    HMODULE module=GetModuleHandleW(args[10].c_str());if(!module)return 82;
    const auto query=reinterpret_cast<Query>(GetProcAddress(module,"BeamRT_PipelineAuditQuery"));
    const auto read=reinterpret_cast<Read>(GetProcAddress(module,"BeamRT_PipelineAuditReadMatch"));
    const auto disable=reinterpret_cast<Disable>(GetProcAddress(module,"BeamRT_PipelineAuditDisable"));if(!query || !read || !disable)return 82;
    ComPtr<IDXGIFactory6> factory;if(FAILED(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory))))return 83;ComPtr<IDXGIAdapter> adapter;
    if(args[2]==L"warp"){if(FAILED(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter))))return 83;}
    else if(args[2]==L"hardware")for(UINT i=0;!adapter;++i){ComPtr<IDXGIAdapter1> candidate;
        if(FAILED(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&candidate))))return 83;
        DXGI_ADAPTER_DESC1 d{};if(FAILED(candidate->GetDesc1(&d)))return 83;
        if(!(d.Flags&DXGI_ADAPTER_FLAG_SOFTWARE) && SUCCEEDED(D3D12CreateDevice(candidate.Get(),D3D_FEATURE_LEVEL_11_0,__uuidof(ID3D12Device),nullptr)))candidate.As(&adapter);
    }else return 83;
    // Import observation automatically starts the separately requested audit
    // before this device output reaches the fixture. No explicit Start call.
    ComPtr<ID3D12Device> device;if(FAILED(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device))))return 84;
    BeamRTPipelineFixtureReport report{};
    if(FAILED(query(&report.audit,sizeof(report.audit))) || report.audit.abi!=beamrtPipelineAuditInfoABI
        || !report.audit.enabled || !report.audit.healthy || report.audit.ownerThread!=GetCurrentThreadId())return 85;
    D3D12_DESCRIPTOR_RANGE range{D3D12_DESCRIPTOR_RANGE_TYPE_SRV,3,0,0,0};D3D12_ROOT_PARAMETER params[2]{};
    params[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;params[0].DescriptorTable={1,&range};
    params[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;params[1].Constants={0,0,1};
    D3D12_ROOT_SIGNATURE_DESC desc{2,params,0,nullptr,D3D12_ROOT_SIGNATURE_FLAG_NONE};ComPtr<ID3DBlob> blob,error;
    if(FAILED(D3D12SerializeRootSignature(&desc,D3D_ROOT_SIGNATURE_VERSION_1,&blob,&error)))return 86;
    ComPtr<ID3D12RootSignature> root;if(FAILED(device->CreateRootSignature(0,blob->GetBufferPointer(),blob->GetBufferSize(),IID_PPV_ARGS(&root))))return 86;
    std::vector<ComPtr<ID3D12RootSignature>> pressure(96);
    for(UINT i=0;i<pressure.size();++i){params[1].Constants.RegisterSpace=i+1;ComPtr<ID3DBlob> varied;
        if(FAILED(D3D12SerializeRootSignature(&desc,D3D_ROOT_SIGNATURE_VERSION_1,&varied,&error))
            || FAILED(device->CreateRootSignature(0,varied->GetBufferPointer(),varied->GetBufferSize(),IID_PPV_ARGS(&pressure[i]))))return 86;
    }
    params[1].Constants.RegisterSpace=0;
    if(FAILED(query(&report.audit,sizeof(report.audit))) || !report.audit.healthy || report.audit.liveLayouts<=32
        || !report.audit.cacheEvictions || report.audit.metadataBytes>beamrtPipelineMetadataBudget)return 86;
    pressure.clear();
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pso{};pso.pRootSignature=root.Get();pso.VS={vs.data(),vs.size()};pso.PS={ps.data(),ps.size()};
    pso.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;pso.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;pso.RasterizerState.DepthClipEnable=TRUE;
    pso.BlendState.RenderTarget[0].RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;pso.SampleMask=UINT_MAX;
    pso.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;pso.NumRenderTargets=1;pso.RTVFormats[0]=DXGI_FORMAT_R32G32B32A32_FLOAT;pso.SampleDesc.Count=1;
    if(conflict){const ULONG_PTR foreign=1;
        if(FAILED(root->SetPrivateData(beamrtPipelineRootEvidenceGuid,sizeof(foreign),&foreign)))return 87;}
    ComPtr<ID3D12PipelineState> pipeline;if(FAILED(device->CreateGraphicsPipelineState(&pso,IID_PPV_ARGS(&pipeline))))return 87;
    if(FAILED(query(&report.audit,sizeof(report.audit))))return 88;
    if(conflict){if(report.audit.healthy || report.audit.creationMatchAvailable
        || report.audit.failureReason!=static_cast<uint32_t>(BeamRTPipelineFailure::rootEvidenceConflict) || report.audit.failureResult!=E_INVALIDARG)return 88;}
    else if(!report.audit.healthy || report.audit.failureReason || report.audit.liveRootTags!=1 || report.audit.liveLayouts!=1)return 88;
    report.matched=report.audit.creationMatchAvailable;
    if(report.matched){std::vector<uint8_t> bytes(65536);ID3D12RootSignature* r=nullptr;ID3D12PipelineState* p=nullptr;
        if(FAILED(read(bytes.data(),static_cast<uint32_t>(bytes.size()),&report.rootBytes,&r,&p)))return 88;
        ComPtr<ID3D12RootSignature> seenRoot;seenRoot.Attach(r);ComPtr<ID3D12PipelineState> seenPipeline;seenPipeline.Attach(p);
        ComPtr<ID3D12Device> owner;if(FAILED(seenPipeline->GetDevice(IID_PPV_ARGS(&owner))))return 88;
        report.ownerMatches=owner.Get()==device.Get() && r==root.Get() && p==pipeline.Get()
            && report.rootBytes==blob->GetBufferSize() && std::memcmp(bytes.data(),blob->GetBufferPointer(),report.rootBytes)==0?1u:0u;
        if(!report.ownerMatches)return 88;
        BCRYPT_ALG_HANDLE algorithm=nullptr;if(BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0)<0)return 88;
        const NTSTATUS hashed=BCryptHash(algorithm,nullptr,0,bytes.data(),report.rootBytes,report.rootDigest,sizeof(report.rootDigest));
        BCryptCloseAlgorithmProvider(algorithm,0);if(hashed<0)return 88;
    }
    if(FAILED(disable()))return 89;
    auto& startup=report.startup;startup.bytes=sizeof(startup);startup.magic=beamrtStartupFixtureMagic;startup.processId=GetCurrentProcessId();
    using StartupQuery=BOOL(WINAPI*)(BeamRTStartupStatus*,DWORD);
    const auto status=reinterpret_cast<StartupQuery>(GetProcAddress(module,"BeamRT_StartupQuery"));startup.queryOK=status && status(&startup.status,sizeof(startup.status));
    startup.initialThread=startup.status.attachThread==GetCurrentThreadId();startup.cwdMatches=std::filesystem::current_path()==std::filesystem::path(args[8]).parent_path();
    const std::vector<std::wstring> expected={L"",L"space value",L"ends\\",L"a\\\"b",L"\u96ea",L"--launch-reviewed"};bool equal=true;
    for(size_t i=0;i<expected.size();++i)equal=equal && args[16+i]==expected[i];startup.argsMatch=equal?1u:0u;
    if(!writeNew(args[8],&report,sizeof(report)))return 90;const int hold=_wtoi(args[12].c_str());if(hold>0 && hold<=20000)Sleep(static_cast<DWORD>(hold));
    const DWORD code=0;if(!writeNew(args[8]+L".done",&code,sizeof(code)))return 91;return 0;
}
