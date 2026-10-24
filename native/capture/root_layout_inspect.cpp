// CPU-only SDK deserialization of an existing serialized root. No D3D12
// device, process attachment, GPU work, hooks or game files are involved.
#include <d3d12.h>
#include <wrl/client.h>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>

int wmain(int argc, wchar_t** argv) {
    try {
        if (argc != 2) throw std::runtime_error("root_layout_inspect <existing root file>");
        std::ifstream input(std::filesystem::path(argv[1]), std::ios::binary | std::ios::ate);
        if (!input || input.tellg() <= 0 || input.tellg() > 65536)
            throw std::runtime_error("Root file missing or outside 1..65536 byte bound");
        std::vector<unsigned char> bytes(static_cast<size_t>(input.tellg()));
        input.seekg(0);
        input.read(reinterpret_cast<char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
        if (!input) throw std::runtime_error("Truncated root file");
        Microsoft::WRL::ComPtr<ID3D12VersionedRootSignatureDeserializer> decoder;
        const auto hr = D3D12CreateVersionedRootSignatureDeserializer(bytes.data(), bytes.size(), IID_PPV_ARGS(&decoder));
        if (FAILED(hr)) throw std::runtime_error("SDK root deserialization refused");
        const auto* desc = decoder->GetUnconvertedRootSignatureDesc();
        if (!desc || desc->Version != D3D_ROOT_SIGNATURE_VERSION_1_0)
            throw std::runtime_error("Only unchanged version 1.0 layout reporting is implemented");
        const auto& root = desc->Desc_1_0;
        if (root.NumParameters > 64 || root.NumStaticSamplers > 64)
            throw std::runtime_error("Root metadata exceeds inspector bound");
        std::cout << "{\"sdkDeserialized\":true,\"gpuDeviceCreated\":false,\"version\":\"1.0\",\"flags\":"
                  << static_cast<unsigned>(root.Flags) << ",\"staticSamplerCount\":" << root.NumStaticSamplers
                  << ",\"parameters\":[";
        for (UINT i = 0; i < root.NumParameters; ++i) {
            const auto& p = root.pParameters[i];
            if (i) std::cout << ',';
            std::cout << "{\"index\":" << i << ",\"type\":" << static_cast<unsigned>(p.ParameterType)
                      << ",\"visibility\":" << static_cast<unsigned>(p.ShaderVisibility);
            if (p.ParameterType == D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE) {
                if (p.DescriptorTable.NumDescriptorRanges > 128) throw std::runtime_error("Too many ranges");
                std::cout << ",\"ranges\":[";
                for (UINT j = 0; j < p.DescriptorTable.NumDescriptorRanges; ++j) {
                    const auto& r = p.DescriptorTable.pDescriptorRanges[j];
                    if (j) std::cout << ',';
                    std::cout << "{\"type\":" << static_cast<unsigned>(r.RangeType)
                              << ",\"count\":" << r.NumDescriptors << ",\"baseRegister\":" << r.BaseShaderRegister
                              << ",\"space\":" << r.RegisterSpace << ",\"tableOffset\":" << r.OffsetInDescriptorsFromTableStart << '}';
                }
                std::cout << ']';
            } else if (p.ParameterType == D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS) {
                std::cout << ",\"register\":" << p.Constants.ShaderRegister << ",\"space\":"
                          << p.Constants.RegisterSpace << ",\"count\":" << p.Constants.Num32BitValues;
            } else if (p.ParameterType == D3D12_ROOT_PARAMETER_TYPE_CBV ||
                       p.ParameterType == D3D12_ROOT_PARAMETER_TYPE_SRV ||
                       p.ParameterType == D3D12_ROOT_PARAMETER_TYPE_UAV) {
                std::cout << ",\"register\":" << p.Descriptor.ShaderRegister
                          << ",\"space\":" << p.Descriptor.RegisterSpace;
            } else throw std::runtime_error("Unknown parameter type");
            std::cout << '}';
        }
        std::cout << "]}\n";
        return 0;
    } catch (const std::exception& e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
