// Separate-process, one-batch loopback D3D12 diagnostic. Never attaches to BeamNG
// or borrows its resources. Raw mesh data remains in memory and is never saved.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <bcrypt.h>
#include "../gi/gpu_fixture_host.h"
#include <array>
#include <chrono>
#include <iomanip>
#include <sstream>
struct Triangle { float a[3]; uint32_t owner; float b[3]; uint32_t reference; float c[3]; uint32_t reserved; };
struct Ray { float origin[3],reach,direction[3]; uint32_t excluded; };
struct Hit { uint32_t owner,reference; float distance; uint32_t state; };
struct Header { char magic[8]; uint32_t version,triangles,rays,triangleStride,rayStride,bytes; char token[32]; };
struct Reply { char magic[8]; uint32_t version,status,triangles,rays,hardware,stride; char token[32]; };
static_assert(sizeof(Triangle)==48 && sizeof(Ray)==32 && sizeof(Hit)==16 && sizeof(Header)==64 && sizeof(Reply)==64,"protocol ABI");
static constexpr uint32_t maxTriangles=500000,maxRays=32;
static void validate(const std::vector<Triangle>& tris,const std::vector<Ray>& rays) {
    require(!tris.empty() && tris.size()<=maxTriangles && !rays.empty() && rays.size()<=maxRays,"count budget exceeded");
    for(size_t i=0;i<tris.size();++i) {
        const auto& t=tris[i];require((t.owner==1 || t.owner==2) && t.reference==i && t.reserved==0,"invalid triangle identity/layout");
        for(const float* p:{t.a,t.b,t.c})for(unsigned j=0;j<3;++j)require(std::isfinite(p[j]) && std::abs(p[j])<=10000,"invalid rebased triangle position");
    }
    for(const auto& r:rays) {
        float n=0;for(unsigned j=0;j<3;++j){require(std::isfinite(r.origin[j]) && std::abs(r.origin[j])<=10000 && std::isfinite(r.direction[j]),"invalid ray");n+=r.direction[j]*r.direction[j];}
        require(std::abs(n-1)<.001f && std::isfinite(r.reach) && r.reach>.16f && r.reach<=1000 && r.excluded<=2,"invalid ray range/owner/direction");
    }
}
struct Probe {
    ComPtr<ID3D12Device> device; std::unique_ptr<Host> host;
    ComPtr<ID3D12RootSignature> root; ComPtr<ID3D12PipelineState> pipeline;
    std::wstring adapterName;bool hardware=false,debugEnabled=false;
    explicit Probe(const std::filesystem::path& shader,bool warp) {
        ComPtr<ID3D12Debug> debug;debugEnabled=SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));if(debugEnabled)debug->EnableDebugLayer();
        ComPtr<IDXGIFactory6> factory;hr(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)));
        if(warp){ComPtr<IDXGIAdapter> a;hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&a)));hr(D3D12CreateDevice(a.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));adapterName=L"WARP";}
        else for(UINT i=0;!device;++i) {
            ComPtr<IDXGIAdapter1> a;require(SUCCEEDED(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&a))),"no hardware GPU");
            DXGI_ADAPTER_DESC1 d{};hr(a->GetDesc1(&d));if(d.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)continue;
            if(SUCCEEDED(D3D12CreateDevice(a.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)))){adapterName=d.Description;hardware=true;}
        }
        host=std::make_unique<Host>(device.Get());
        D3D12_ROOT_PARAMETER p[4]{};
        p[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_SRV;p[0].Descriptor.ShaderRegister=0;
        p[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_SRV;p[1].Descriptor.ShaderRegister=1;
        p[2].ParameterType=D3D12_ROOT_PARAMETER_TYPE_UAV;p[2].Descriptor.ShaderRegister=0;
        p[3].ParameterType=D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;p[3].Constants.ShaderRegister=0;p[3].Constants.Num32BitValues=2;
        D3D12_ROOT_SIGNATURE_DESC desc{};desc.NumParameters=4;desc.pParameters=p;
        ComPtr<ID3DBlob> blob,errors;hr(D3D12SerializeRootSignature(&desc,D3D_ROOT_SIGNATURE_VERSION_1,&blob,&errors));
        hr(device->CreateRootSignature(0,blob->GetBufferPointer(),blob->GetBufferSize(),IID_PPV_ARGS(&root)));
        const auto cs=file(shader.c_str());D3D12_COMPUTE_PIPELINE_STATE_DESC ps{};ps.pRootSignature=root.Get();ps.CS={cs.data(),cs.size()};
        hr(device->CreateComputePipelineState(&ps,IID_PPV_ARGS(&pipeline)));
        std::wcout<<L"Vehicle ray probe GPU: "<<adapterName<<L"; own device/queue, no game attachment\n";
    }
    std::vector<Hit> trace(const std::vector<Triangle>& tris,const std::vector<Ray>& rays) {
        validate(tris,rays);const auto tb=tris.size()*sizeof(Triangle),rb=rays.size()*sizeof(Ray),hb=rays.size()*sizeof(Hit);
        auto tu=make(device.Get(),buffer(tb),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);
        auto ru=make(device.Get(),buffer(rb),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);
        fill(tu.Get(),tris.data(),tb);fill(ru.Get(),rays.data(),rb);
        auto td=make(device.Get(),buffer(tb),D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_COPY_DEST);
        auto rd=make(device.Get(),buffer(rb),D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_COPY_DEST);
        auto outputDesc=buffer(hb);outputDesc.Flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        auto output=make(device.Get(),outputDesc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        auto readback=make(device.Get(),buffer(hb),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
        host->begin();host->list->CopyBufferRegion(td.Get(),0,tu.Get(),0,tb);host->list->CopyBufferRegion(rd.Get(),0,ru.Get(),0,rb);
        transition(host->list.Get(),td.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        transition(host->list.Get(),rd.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
        host->list->SetPipelineState(pipeline.Get());host->list->SetComputeRootSignature(root.Get());
        host->list->SetComputeRootShaderResourceView(0,td->GetGPUVirtualAddress());host->list->SetComputeRootShaderResourceView(1,rd->GetGPUVirtualAddress());
        host->list->SetComputeRootUnorderedAccessView(2,output->GetGPUVirtualAddress());
        const uint32_t counts[]={static_cast<uint32_t>(tris.size()),static_cast<uint32_t>(rays.size())};host->list->SetComputeRoot32BitConstants(3,2,counts,0);
        host->list->Dispatch((counts[1]+63)/64,1,1);
        transition(host->list.Get(),output.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_SOURCE);
        host->list->CopyBufferRegion(readback.Get(),0,output.Get(),0,hb);host->execute();
        // If retirement fails, stop ONLY this helper process with its owned GPU
        // resources still alive. Never free them early and continue serving.
        try{host->wait();}catch(...){std::cerr<<"GPU retirement failed; terminating isolated helper\n";ExitProcess(5);}
        std::vector<Hit> result(rays.size());void* mapped=nullptr;D3D12_RANGE readRange{0,hb};hr(readback->Map(0,&readRange,&mapped));
        std::memcpy(result.data(),mapped,hb);D3D12_RANGE noWrite{0,0};readback->Unmap(0,&noWrite);
        return result;
    }
};
struct Socket {
    SOCKET value=INVALID_SOCKET;
    Socket()=default;explicit Socket(SOCKET s):value(s){}
    ~Socket(){if(value!=INVALID_SOCKET)closesocket(value);}
    Socket(const Socket&)=delete;Socket& operator=(const Socket&)=delete;
};
static void receive(SOCKET s,void* output,size_t bytes) {
    auto* p=static_cast<char*>(output);
    while(bytes){const int n=recv(s,p,static_cast<int>(std::min<size_t>(bytes,65536)),0);require(n>0,"socket receive ended/timed out");p+=n;bytes-=static_cast<size_t>(n);}
}
static void sendAll(SOCKET s,const void* input,size_t bytes) {
    auto* p=static_cast<const char*>(input);
    while(bytes){const int n=send(s,p,static_cast<int>(std::min<size_t>(bytes,65536)),0);require(n>0,"socket send failed");p+=n;bytes-=static_cast<size_t>(n);}
}
static std::string token() {
    std::array<unsigned char,16> data{};require(BCryptGenRandom(nullptr,data.data(),static_cast<ULONG>(data.size()),BCRYPT_USE_SYSTEM_PREFERRED_RNG)==0,"session randomness failed");
    std::ostringstream out;for(auto b:data)out<<std::hex<<std::setw(2)<<std::setfill('0')<<unsigned(b);return out.str();
}
static void serve(Probe& probe,const std::filesystem::path& config) {
    WSADATA w{};require(WSAStartup(MAKEWORD(2,2),&w)==0,"Winsock initialization failed");
    Socket listener(socket(AF_INET,SOCK_STREAM,IPPROTO_TCP));require(listener.value!=INVALID_SOCKET,"socket failed");
    BOOL exclusive=TRUE;require(setsockopt(listener.value,SOL_SOCKET,SO_EXCLUSIVEADDRUSE,reinterpret_cast<char*>(&exclusive),sizeof(exclusive))==0,"exclusive bind failed");
    sockaddr_in address{};address.sin_family=AF_INET;address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);address.sin_port=0;
    require(bind(listener.value,reinterpret_cast<sockaddr*>(&address),sizeof(address))==0 && listen(listener.value,1)==0,"loopback bind/listen failed");
    int length=sizeof(address);require(getsockname(listener.value,reinterpret_cast<sockaddr*>(&address),&length)==0,"socket endpoint failed");
    const auto secret=token();const auto expiry=std::chrono::system_clock::to_time_t(std::chrono::system_clock::now())+600;
    const auto temp=config.wstring()+L".tmp";
    {std::ofstream out(temp,std::ios::trunc);require(bool(out),"endpoint file unavailable");out<<"{\"schema\":\"beamrt.gpu-ray-probe.v1\",\"host\":\"127.0.0.1\",\"port\":"<<ntohs(address.sin_port)
        <<",\"expires\":"<<expiry<<",\"hardware\":"<<(probe.hardware?"true":"false")<<",\"token\":\""<<secret<<"\"}";out.flush();require(bool(out),"endpoint write failed");}
    require(MoveFileExW(temp.c_str(),config.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)!=0,"endpoint publication failed");
    std::cout<<"Ready for one authenticated localhost batch; expires in 10 minutes. No mesh files written.\n"<<std::flush;
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::minutes(10);
    while(std::chrono::steady_clock::now()<deadline) {
        fd_set ready;FD_ZERO(&ready);FD_SET(listener.value,&ready);timeval wait{1,0};const int readable=select(0,&ready,nullptr,nullptr,&wait);
        require(readable!=SOCKET_ERROR,"listener wait failed");if(readable==0)continue;
        Socket client(accept(listener.value,nullptr,nullptr));if(client.value==INVALID_SOCKET)continue;
        const DWORD timeout=30000;setsockopt(client.value,SOL_SOCKET,SO_RCVTIMEO,reinterpret_cast<const char*>(&timeout),sizeof(timeout));
        setsockopt(client.value,SOL_SOCKET,SO_SNDTIMEO,reinterpret_cast<const char*>(&timeout),sizeof(timeout));
        Header h{};try{receive(client.value,&h,sizeof(h));}catch(...){continue;}
        if(std::memcmp(h.magic,"BRGIN01\0",8)!=0 || h.version!=1 || std::memcmp(h.token,secret.data(),32)!=0)continue;
        require(h.triangles>0 && h.triangles<=maxTriangles && h.rays>0 && h.rays<=maxRays && h.triangleStride==48 && h.rayStride==32,"invalid packet counts/strides");
        require(h.bytes==uint64_t(h.triangles)*48+uint64_t(h.rays)*32,"invalid packet length");
        std::vector<Triangle> tris(h.triangles);std::vector<Ray> rays(h.rays);
        receive(client.value,tris.data(),tris.size()*sizeof(Triangle));receive(client.value,rays.data(),rays.size()*sizeof(Ray));
        auto result=probe.trace(tris,rays);
        Reply reply{};std::memcpy(reply.magic,"BRGOUT1\0",8);reply.version=1;reply.triangles=h.triangles;reply.rays=h.rays;reply.hardware=probe.hardware?1u:0u;reply.stride=16;std::memcpy(reply.token,secret.data(),32);
        sendAll(client.value,&reply,sizeof(reply));sendAll(client.value,result.data(),result.size()*sizeof(Hit));
        std::cout<<"Completed GPU readback: "<<tris.size()<<" full triangle references, "<<rays.size()<<" rays. Helper exiting.\n";return;
    }
    throw std::runtime_error("unused endpoint expired");
}
static void selfTest(Probe& probe) {
    std::vector<Triangle> tris={{{2,-2,-2},1,{2,2,-2},0,{2,0,2},0},{{4,-2,-2},2,{4,2,-2},1,{4,0,2},0}};
    const std::vector<Ray> rays={{{0,0,0},10,{1,0,0},0},{{0,0,0},10,{1,0,0},1},{{0,0,0},10,{1,0,0},2},
      {{0,5,0},10,{1,0,0},0},{{0,0,0},1,{1,0,0},0},{{3,0,0},10,{1,0,0},0},{{3,0,0},10,{-1,0,0},0},{{2,0,0},10,{1,0,0},0}};
    auto hits=probe.trace(tris,rays);
    const uint32_t owners[]={1,2,1,0,0,2,1,2};unsigned checks=0;
    for(size_t i=0;i<hits.size();++i){require(hits[i].state==(owners[i]?1u:0u),"GPU hit/miss mismatch");if(owners[i])require(hits[i].owner==owners[i] && hits[i].reference==owners[i]-1,"GPU nearest identity/exclusion mismatch");++checks;}
    auto invalid=rays;invalid[0].direction[0]=2;bool rejected=false;try{probe.trace(tris,invalid);}catch(...){rejected=true;}require(rejected,"nonunit ray accepted");++checks;
    auto bad=tris;bad[0].reference=99;rejected=false;try{probe.trace(bad,rays);}catch(...){rejected=true;}require(rejected,"invalid provenance accepted");++checks;
    // Stress the full supported count, with nearest identity unchanged.
    std::vector<Triangle> large(maxTriangles,tris[1]);for(uint32_t i=0;i<maxTriangles;++i)large[i].reference=i;
    large[0]=tris[0];auto dense=probe.trace(large,{rays[0],rays[1]});
    require(dense[0].owner==1 && dense[0].reference==0 && std::abs(dense[0].distance-2)<.001f,"full-budget nearest mismatch");
    require(dense[1].owner==2 && dense[1].reference==1 && std::abs(dense[1].distance-4)<.001f,"full-budget exclusion mismatch");checks+=2;
    std::cout<<checks<<" hardware/validation checks passed; 500000-reference stress included. Debug layer: "<<(probe.debugEnabled?"enabled":"unavailable")<<". Isolated compute, not DXR/game integration.\n";
}
int wmain(int argc,wchar_t** argv) {
    try {
        require(argc==3 || argc==4,"usage: probe shader (--self-test | endpoint.json) [--warp]");
        const bool warp=argc==4 && std::wstring(argv[3])==L"--warp";require(argc==3 || warp,"unknown option");
        Probe probe(argv[1],warp);
        if(std::wstring(argv[2])==L"--self-test")selfTest(probe);else {require(!warp,"live endpoint requires a hardware GPU");serve(probe,argv[2]);}
        return 0;
    }catch(const std::exception& e){std::cerr<<"Vehicle GPU probe failed: "<<e.what()<<'\n';return 1;}
}
