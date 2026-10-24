#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <bcrypt.h>
#include "../gi/gpu_fixture_host.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <functional>
#include <iomanip>
#include <numeric>
#include <sstream>
struct Triangle {float a[3];uint32_t owner;float b[3];uint32_t reference;float c[3];uint32_t reserved;};
struct Topology {uint32_t left,right,first,count;};
struct Node {float low[3];uint32_t left;float high[3];uint32_t right;uint32_t first,count,pad0,pad1;};
struct Hit {uint32_t owner,reference;float distance;uint32_t state;};
struct Pixel {Hit primary,full,excluded;};
struct Camera {float right[4],forward[4],up[4],frustum[4];uint32_t counts[4],options[4];};
struct Header {char magic[8];uint32_t version,triangles,nodes,width,height,bytes;char token[32];};
struct Reply {char magic[8];uint32_t version,status,width,height,hardware,stride;char token[32];};
struct Check {char magic[8];uint32_t version,count,width,height,reserved0,reserved1;char token[32];};
static_assert(sizeof(Triangle)==48&&sizeof(Topology)==16&&sizeof(Node)==48&&sizeof(Pixel)==48&&sizeof(Camera)==96&&sizeof(Header)==64&&sizeof(Reply)==64&&sizeof(Check)==64,"image ABI");
constexpr uint32_t none=0xffffffff,maxTriangles=500000;
static std::vector<Node> refit(const std::vector<Triangle>& tris,const std::vector<Topology>& topology,const std::vector<uint32_t>& order) {
    require(!tris.empty()&&tris.size()<=maxTriangles&&order.size()==tris.size()&&!topology.empty()&&topology.size()<=tris.size()*2-1,"image geometry count budget");
    for(size_t i=0;i<tris.size();++i) {
        const auto& t=tris[i];require(t.reference==i&&(t.owner==1||t.owner==2)&&t.reserved==0,"triangle identity invalid");
        for(const float* p:{t.a,t.b,t.c})for(unsigned j=0;j<3;++j)require(std::isfinite(p[j])&&std::abs(p[j])<=10000,"triangle coordinate invalid");
    }
    std::vector<uint8_t> permutation(tris.size()),covered(tris.size()),parents(topology.size());std::vector<uint32_t> depths(topology.size());
    for(auto index:order){require(index<tris.size()&&!permutation[index],"order is not a full permutation");permutation[index]=1;}
    for(size_t i=0;i<topology.size();++i) {
        const auto& t=topology[i];require(depths[i]<=40,"BVH exceeds stack depth contract");
        if(t.left==none) {
            require(t.right==none&&t.count>0&&t.count<=4096&&t.first<=tris.size()&&t.count<=tris.size()-t.first,"invalid leaf range/budget");
            for(uint32_t j=t.first;j<t.first+t.count;++j){require(!covered[j],"overlapping leaf range");covered[j]=1;}
        } else {
            require(t.count==0&&t.left>i&&t.right>i&&t.left<topology.size()&&t.right<topology.size()&&t.left!=t.right,"invalid ordered BVH children");
            require(++parents[t.left]==1&&++parents[t.right]==1,"shared BVH child");depths[t.left]=depths[t.right]=depths[i]+1;
        }
        require(i==0?parents[i]==0:parents[i]==1,"disconnected BVH node");
    }
    require(std::all_of(covered.begin(),covered.end(),[](uint8_t n){return n==1;}),"missing leaf triangle references");
    std::vector<Node> nodes(topology.size());
    for(size_t end=topology.size();end>0;--end) {
        const size_t i=end-1;const auto& t=topology[i];auto& n=nodes[i];n.left=t.left;n.right=t.right;n.first=t.first;n.count=t.count;
        for(unsigned j=0;j<3;++j){n.low[j]=std::numeric_limits<float>::infinity();n.high[j]=-n.low[j];}
        if(t.left==none) {
            for(uint32_t k=t.first;k<t.first+t.count;++k)for(const float* p:{tris[order[k]].a,tris[order[k]].b,tris[order[k]].c})
                for(unsigned j=0;j<3;++j){n.low[j]=std::min(n.low[j],p[j]);n.high[j]=std::max(n.high[j],p[j]);}
        } else for(unsigned j=0;j<3;++j){n.low[j]=std::min(nodes[t.left].low[j],nodes[t.right].low[j]);n.high[j]=std::max(nodes[t.left].high[j],nodes[t.right].high[j]);}
    }
    return nodes;
}
static void validateCamera(const Camera& c) {
    for(const float* v:{c.right,c.forward,c.up,c.frustum})for(unsigned j=0;j<4;++j)require(std::isfinite(v[j]),"nonfinite camera");
    require(c.right[3]>0&&c.right[3]<=10&&c.forward[3]>c.right[3]+.2f&&c.forward[3]<=1e8f&&c.up[3]>.16f&&c.up[3]<=1000,"camera segment range invalid");
    require(c.frustum[0]<c.frustum[1]&&c.frustum[3]<c.frustum[2],"camera frustum invalid");
    for(float v:c.frustum)require(std::abs(v)<=10,"camera frustum magnitude invalid");
    for(const float* v:{c.right,c.forward,c.up}){float n=0;for(unsigned j=0;j<3;++j)n+=v[j]*v[j];require(std::abs(n-1)<.001f,"nonunit camera basis");}
    for(const auto pair:{std::pair<const float*,const float*>{c.right,c.forward},{c.right,c.up},{c.forward,c.up}}){float d=0;for(unsigned j=0;j<3;++j)d+=pair.first[j]*pair.second[j];require(std::abs(d)<.001f,"nonorthogonal camera");}
    const float handed=(c.right[1]*c.forward[2]-c.right[2]*c.forward[1])*c.up[0]+(c.right[2]*c.forward[0]-c.right[0]*c.forward[2])*c.up[1]+(c.right[0]*c.forward[1]-c.right[1]*c.forward[0])*c.up[2];require(handed>.999f,"camera handedness invalid");
}
struct ImageHost {
    ComPtr<ID3D12Device> device;std::unique_ptr<Host> host;ComPtr<ID3D12RootSignature> root;ComPtr<ID3D12PipelineState> pipeline,referencePipeline;
    bool hardware=false,debugEnabled=false;
    explicit ImageHost(const std::filesystem::path& shader,bool warp) {
        ComPtr<ID3D12Debug> debug;debugEnabled=SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)));if(debugEnabled)debug->EnableDebugLayer();
        ComPtr<IDXGIFactory6> factory;hr(CreateDXGIFactory2(0,IID_PPV_ARGS(&factory)));
        if(warp){ComPtr<IDXGIAdapter> a;hr(factory->EnumWarpAdapter(IID_PPV_ARGS(&a)));hr(D3D12CreateDevice(a.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)));}
        else for(UINT i=0;!device;++i) {
            ComPtr<IDXGIAdapter1> a;require(SUCCEEDED(factory->EnumAdapterByGpuPreference(i,DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,IID_PPV_ARGS(&a))),"hardware GPU unavailable");
            DXGI_ADAPTER_DESC1 d{};hr(a->GetDesc1(&d));if(d.Flags&DXGI_ADAPTER_FLAG_SOFTWARE)continue;
            if(SUCCEEDED(D3D12CreateDevice(a.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)))){hardware=true;std::wcout<<L"GPU image host: "<<d.Description<<L"; own resources, no game attachment\n";}
        }
        host=std::make_unique<Host>(device.Get());D3D12_ROOT_PARAMETER p[5]{};
        for(unsigned i=0;i<3;++i){p[i].ParameterType=D3D12_ROOT_PARAMETER_TYPE_SRV;p[i].Descriptor.ShaderRegister=i;}
        p[3].ParameterType=D3D12_ROOT_PARAMETER_TYPE_UAV;p[4].ParameterType=D3D12_ROOT_PARAMETER_TYPE_CBV;
        D3D12_ROOT_SIGNATURE_DESC desc{};desc.NumParameters=5;desc.pParameters=p;ComPtr<ID3DBlob> blob,error;
        hr(D3D12SerializeRootSignature(&desc,D3D_ROOT_SIGNATURE_VERSION_1,&blob,&error));hr(device->CreateRootSignature(0,blob->GetBufferPointer(),blob->GetBufferSize(),IID_PPV_ARGS(&root)));
        const auto cs=file(shader.c_str());D3D12_COMPUTE_PIPELINE_STATE_DESC ps{};ps.pRootSignature=root.Get();ps.CS={cs.data(),cs.size()};hr(device->CreateComputePipelineState(&ps,IID_PPV_ARGS(&pipeline)));
        const auto reference=file((shader.parent_path()/L"image-reference.cso").c_str());ps.CS={reference.data(),reference.size()};hr(device->CreateComputePipelineState(&ps,IID_PPV_ARGS(&referencePipeline)));
    }
    std::vector<Pixel> render(const std::vector<Triangle>& tris,const std::vector<Topology>& topology,const std::vector<uint32_t>& order,Camera camera,uint32_t width,uint32_t height,bool linear=false,uint32_t selected=none) {
        auto nodes=refit(tris,topology,order);validateCamera(camera);require(width>0&&width<=128&&height>0&&height<=96,"image pixel budget");
        require(selected==none||(linear&&selected<uint64_t(width)*height),"invalid selected reference pixel");
        camera.counts[0]=static_cast<uint32_t>(tris.size());camera.counts[1]=static_cast<uint32_t>(nodes.size());camera.counts[2]=width;camera.counts[3]=height;camera.options[0]=linear?1u:0u;
        camera.options[1]=selected==none?0u:1u;camera.options[2]=selected==none?0u:selected;
        host->begin();std::vector<ComPtr<ID3D12Resource>> resources,uploads;
        auto input=[&](const void* data,size_t bytes){auto up=make(device.Get(),buffer(bytes),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);fill(up.Get(),data,bytes);
            auto gpu=make(device.Get(),buffer(bytes),D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_COPY_DEST);host->list->CopyBufferRegion(gpu.Get(),0,up.Get(),0,bytes);
            transition(host->list.Get(),gpu.Get(),D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);uploads.push_back(up);resources.push_back(gpu);};
        input(tris.data(),tris.size()*48);input(nodes.data(),nodes.size()*48);input(order.data(),order.size()*4);
        auto cb=make(device.Get(),buffer(256),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);fill(cb.Get(),&camera,sizeof(camera));
        const auto bytes=size_t(width)*height*sizeof(Pixel);auto desc=buffer(bytes);desc.Flags=D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
        auto output=make(device.Get(),desc,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
        const size_t readBytes=selected==none?bytes:sizeof(Pixel);
        auto readback=make(device.Get(),buffer(readBytes),D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
        host->list->SetPipelineState(linear?referencePipeline.Get():pipeline.Get());host->list->SetComputeRootSignature(root.Get());
        for(unsigned i=0;i<3;++i)host->list->SetComputeRootShaderResourceView(i,resources[i]->GetGPUVirtualAddress());
        host->list->SetComputeRootUnorderedAccessView(3,output->GetGPUVirtualAddress());host->list->SetComputeRootConstantBufferView(4,cb->GetGPUVirtualAddress());
        host->list->Dispatch(selected==none?(width+7)/8:1,selected==none?(height+7)/8:1,1);transition(host->list.Get(),output.Get(),D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_SOURCE);
        host->list->CopyBufferRegion(readback.Get(),0,output.Get(),selected==none?0:uint64_t(selected)*sizeof(Pixel),readBytes);host->execute();
        try{host->wait();}catch(...){std::cerr<<"Image GPU retirement failed; terminating isolated host\n";ExitProcess(5);}
        std::vector<Pixel> result(readBytes/sizeof(Pixel));void* mapped=nullptr;D3D12_RANGE range{0,readBytes};hr(readback->Map(0,&range,&mapped));std::memcpy(result.data(),mapped,readBytes);D3D12_RANGE noWrite{0,0};readback->Unmap(0,&noWrite);return result;
    }
};
struct Socket {SOCKET value;explicit Socket(SOCKET s):value(s){}~Socket(){if(value!=INVALID_SOCKET)closesocket(value);}Socket(const Socket&)=delete;};
static void receive(SOCKET s,void* output,size_t bytes){auto* p=static_cast<char*>(output);while(bytes){int n=recv(s,p,static_cast<int>(std::min<size_t>(65536,bytes)),0);require(n>0,"image socket receive ended/timed out");p+=n;bytes-=static_cast<size_t>(n);}}
static void sendAll(SOCKET s,const void* data,size_t bytes){auto* p=static_cast<const char*>(data);while(bytes){int n=send(s,p,static_cast<int>(std::min<size_t>(65536,bytes)),0);require(n>0,"image socket send failed");p+=n;bytes-=static_cast<size_t>(n);}}
static void serve(ImageHost& host,const std::filesystem::path& config) {
    WSADATA w{};require(WSAStartup(MAKEWORD(2,2),&w)==0,"Winsock startup failed");Socket listener(socket(AF_INET,SOCK_STREAM,IPPROTO_TCP));require(listener.value!=INVALID_SOCKET,"socket creation failed");
    BOOL exclusive=TRUE;require(setsockopt(listener.value,SOL_SOCKET,SO_EXCLUSIVEADDRUSE,reinterpret_cast<char*>(&exclusive),sizeof(exclusive))==0,"exclusive socket failed");
    sockaddr_in addr{};addr.sin_family=AF_INET;addr.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    require(bind(listener.value,reinterpret_cast<sockaddr*>(&addr),sizeof(addr))==0&&listen(listener.value,1)==0,"loopback listener failed");int len=sizeof(addr);require(getsockname(listener.value,reinterpret_cast<sockaddr*>(&addr),&len)==0,"endpoint failed");
    std::array<unsigned char,16> random{};require(BCryptGenRandom(nullptr,random.data(),16,BCRYPT_USE_SYSTEM_PREFERRED_RNG)==0,"random session failed");std::ostringstream token;for(auto b:random)token<<std::hex<<std::setw(2)<<std::setfill('0')<<unsigned(b);const auto secret=token.str();
    const auto expiry=std::chrono::system_clock::to_time_t(std::chrono::system_clock::now())+1800;const auto temp=config.wstring()+L".tmp";
    {std::ofstream out(temp);require(bool(out),"image endpoint file unavailable");out<<"{\"schema\":\"beamrt.gpu-image.v2\",\"host\":\"127.0.0.1\",\"port\":"<<ntohs(addr.sin_port)<<",\"expires\":"<<expiry<<",\"hardware\":true,\"token\":\""<<secret<<"\"}";out.flush();require(bool(out),"image endpoint write failed");}
    require(MoveFileExW(temp.c_str(),config.c_str(),MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH)!=0,"endpoint publish failed");std::cout<<"Ready for one localhost GPU image; expires in 30 minutes. No geometry files written.\n"<<std::flush;
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::minutes(30);
    while(std::chrono::steady_clock::now()<deadline) {
        fd_set set;FD_ZERO(&set);FD_SET(listener.value,&set);timeval wait{1,0};const int ready=select(0,&set,nullptr,nullptr,&wait);require(ready!=SOCKET_ERROR,"image listener wait failed");if(!ready)continue;
        Socket client(accept(listener.value,nullptr,nullptr));if(client.value==INVALID_SOCKET)continue;const DWORD timeout=60000;setsockopt(client.value,SOL_SOCKET,SO_RCVTIMEO,reinterpret_cast<const char*>(&timeout),sizeof(timeout));setsockopt(client.value,SOL_SOCKET,SO_SNDTIMEO,reinterpret_cast<const char*>(&timeout),sizeof(timeout));
        Header h{};try{receive(client.value,&h,64);}catch(...){continue;}
        if(std::memcmp(h.magic,"BRGIMG1\0",8)||h.version!=2||std::memcmp(h.token,secret.data(),32))continue;
        require(h.triangles>0&&h.triangles<=maxTriangles&&h.nodes>0&&h.nodes<=h.triangles*2-1&&h.width==128&&h.height>=32&&h.height<=96,"invalid image header budget");
        require(h.bytes==uint64_t(h.triangles)*52+uint64_t(h.nodes)*16+64,"invalid image payload size");
        std::vector<Triangle> tris(h.triangles);std::vector<Topology> topology(h.nodes);std::vector<uint32_t> order(h.triangles);Camera camera{};
        receive(client.value,tris.data(),tris.size()*48);receive(client.value,topology.data(),topology.size()*16);receive(client.value,order.data(),order.size()*4);receive(client.value,&camera,64);
        auto result=host.render(tris,topology,order,camera,h.width,h.height);
        Reply reply{};std::memcpy(reply.magic,"BRGIMO1\0",8);reply.version=2;reply.width=h.width;reply.height=h.height;reply.hardware=1;reply.stride=48;std::memcpy(reply.token,secret.data(),32);
        sendAll(client.value,&reply,64);sendAll(client.value,result.data(),result.size()*48);
        Check check{};receive(client.value,&check,64);
        require(!std::memcmp(check.magic,"BRGCHK1\0",8)&&check.version==2&&check.count<=8&&check.width==h.width&&check.height==h.height&&check.reserved0==0&&check.reserved1==0&&!std::memcmp(check.token,secret.data(),32),"invalid bounded reference recheck");
        std::vector<uint32_t> indices(check.count);if(check.count)receive(client.value,indices.data(),indices.size()*4);
        std::vector<uint8_t> records(check.count*52);std::vector<uint8_t> seen(size_t(h.width)*h.height);
        for(size_t i=0;i<indices.size();++i){const auto index=indices[i];require(index<seen.size()&&!seen[index],"invalid/duplicate reference pixel");seen[index]=1;
            auto reference=host.render(tris,topology,order,camera,h.width,h.height,true,index);std::memcpy(records.data()+i*52,&index,4);std::memcpy(records.data()+i*52+4,reference.data(),48);}
        Check checked{};std::memcpy(checked.magic,"BRGCKO1\0",8);checked.version=2;checked.count=check.count;checked.width=h.width;checked.height=h.height;checked.reserved0=1;checked.reserved1=52;std::memcpy(checked.token,secret.data(),32);
        sendAll(client.value,&checked,64);if(!records.empty())sendAll(client.value,records.data(),records.size());
        std::cout<<"GPU image complete: "<<h.triangles<<" triangles, "<<h.nodes<<" BVH nodes, "<<h.width<<'x'<<h.height<<" primary pixels; "<<check.count<<" selected full-scan GPU rechecks. Host exiting.\n";return;
    }
    throw std::runtime_error("unused image session expired");
}
static std::vector<Topology> balanced(uint32_t count) {
    std::vector<Topology> nodes(1);std::function<void(uint32_t,uint32_t,uint32_t)> split=[&](uint32_t n,uint32_t first,uint32_t size){
        if(size<=4){nodes[n]={none,none,first,size};return;}
        const auto left=static_cast<uint32_t>(nodes.size());nodes.resize(nodes.size()+2);nodes[n]={left,left+1,first,0};split(left,first,size/2);split(left+1,first+size/2,size-size/2);
    };split(0,0,count);return nodes;
}
static void selfTest(ImageHost& host) {
    std::vector<Triangle> tris;const uint32_t faces[]={0,2,3,0,3,1,4,5,7,4,7,6,0,1,5,0,5,4,2,6,7,2,7,3,0,4,6,0,6,2,1,3,7,1,7,5};
    for(uint32_t owner=1;owner<=2;++owner){float v[8][3];unsigned k=0;for(int z:{-1,1})for(int y:{-1,1})for(int x:{-1,1}){v[k][0]=(owner==1?-4.f:4.f)+float(x);v[k][1]=float(y)*2;v[k++][2]=float(z);}
        for(unsigned i=0;i<36;i+=3){Triangle t{};std::memcpy(t.a,v[faces[i]],12);std::memcpy(t.b,v[faces[i+1]],12);std::memcpy(t.c,v[faces[i+2]],12);t.owner=owner;t.reference=static_cast<uint32_t>(tris.size());tris.push_back(t);}}
    std::vector<uint32_t> order(tris.size());std::iota(order.begin(),order.end(),0u);auto topology=balanced(static_cast<uint32_t>(tris.size()));
    Camera c{{0,1,0,.1f},{-1,0,0,50},{0,0,1,20},{-.15f,.15f,.1f,-.1f},{},{}};
    auto fast=host.render(tris,topology,order,c,128,64);auto slow=host.render(tris,topology,order,c,128,64,true);
    unsigned positives=0;for(size_t i=0;i<fast.size();++i){require(std::memcmp(&fast[i],&slow[i],48)==0,"BVH image differs from linear GPU reference");if(fast[i].full.state==1&&fast[i].full.owner==2){++positives;require(fast[i].excluded.state==0,"source exclusion failed");}}
    require(positives>0,"no reflected source image samples");
    for(const uint32_t selected:{0u,123u,4095u,8191u}){auto selectedResult=host.render(tris,topology,order,c,128,64,true,selected);require(selectedResult.size()==1&&std::memcmp(selectedResult.data(),&fast[selected],48)==0,"selected full-scan reference pixel mismatch");}
    unsigned guards=0;auto badOrder=order;badOrder[0]=badOrder[1];try{refit(tris,topology,badOrder);}catch(...){++guards;}
    auto bad=topology;bad[0].left=0;try{refit(tris,bad,order);}catch(...){++guards;}
    bad=topology;bad[0].right=bad[0].left;try{refit(tris,bad,order);}catch(...){++guards;}
    bad=topology;for(auto& n:bad)if(n.left==none){--n.count;break;}try{refit(tris,bad,order);}catch(...){++guards;}
    require(guards==4,"invalid topology/order accepted");
    size_t checked=fast.size();Camera rolled=c;const float newRight[]={0,0,1,.1f},newUp[]={0,-1,0,20};std::memcpy(rolled.right,newRight,16);std::memcpy(rolled.up,newUp,16);rolled.frustum[0]=-.08f;
    for(const auto size:{std::pair<UINT,UINT>{128,68},{1,1},{128,96}}){auto a=host.render(tris,topology,order,rolled,size.first,size.second);auto b=host.render(tris,topology,order,rolled,size.first,size.second,true);require(a.size()==b.size()&&std::memcmp(a.data(),b.data(),a.size()*48)==0,"rolled/asymmetric/parallel GPU traversal mismatch");checked+=a.size();}
    std::cout<<checked<<" GPU pixels exactly match independent linear GPU traversal; "<<positives<<" reflected source pixels in baseline; "<<guards<<" invalid-tree guards passed. Debug layer: "<<(host.debugEnabled?"enabled":"unavailable")<<". No game integration.\n";
}
int wmain(int argc,wchar_t** argv) {
    try{require(argc==3||argc==4,"usage: image-host shader (--self-test | endpoint.json) [--warp]");const bool warp=argc==4&&std::wstring(argv[3])==L"--warp";require(argc==3||warp,"unknown argument");ImageHost host(argv[1],warp);if(std::wstring(argv[2])==L"--self-test")selfTest(host);else{require(host.hardware,"image endpoint requires hardware");serve(host,argv[2]);}return 0;}
    catch(const std::exception& e){std::cerr<<"GPU image host failed: "<<e.what()<<'\n';return 1;}
}
