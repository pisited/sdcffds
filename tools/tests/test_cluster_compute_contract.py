"""Offline pinned compute ABI contracts, including root-SRV/table distinction."""
import copy
import hashlib
import unittest
from tools.beamrt_cluster_compute_contract import EXPECTED_PARAMETERS, build_contract, validate_root


def leaf(name, value):
    return {'name': name, 'value': value}


def fixture():
    blobs = {'computeShader': b'fixture shader', 'rootSignature': b'fixture root'}
    pins = [{'kind': kind, 'resource': resource, 'bytes': len(blobs[kind]),
             'sha256': hashlib.sha256(blobs[kind]).hexdigest()}
            for kind, resource in [('computeShader', 30), ('rootSignature', 20)]]
    layout = {'sdkDeserialized': True, 'gpuDeviceCreated': False, 'version': '1.0', 'flags': 0,
              'staticSamplerCount': 0, 'parameters': copy.deepcopy(EXPECTED_PARAMETERS),
              'inputSha256': pins[1]['sha256'], 'inputBytes': pins[1]['bytes']}
    arguments, bindings, resources = {}, [], []
    for parameter, name, register in [(1, 'clusterGrid', 2), (2, 'clusterLightIndices', 3),
                                       (3, 'clusterLights', 4), (4, 'shadowViews', 15)]:
        identifier = 100 + parameter
        arguments[str(parameter)] = {'data': {'name': 'SetComputeRootShaderResourceView', 'children': [
            leaf('RootParameterIndex', parameter), {'name': 'BufferLocation', 'children': [
                leaf('Buffer', identifier), leaf('Offset', 0)]}]}}
        bindings.append({'type': 'DescriptorType.Buffer', 'index': parameter - 1,
                         'resource': 'ResourceId::' + str(identifier), 'byteOffset': 0})
        resources.append({'name': name, 'index': parameter - 1, 'bindNumber': register})
    arguments['0'] = {'data': {'name': 'SetComputeRootConstantBufferView', 'children': [
        leaf('RootParameterIndex', 0), {'name': 'BufferLocation', 'children': [leaf('Buffer', 500), leaf('Offset', 256)]}]}}
    bindings.append({'type': 'DescriptorType.ConstantBuffer', 'index': 0, 'resource': 'ResourceId::500', 'byteOffset': 256})
    recorded = {'phase': 'complete', 'gpuReplayOpened': False, 'pinnedBlobs': pins,
                'creations': [{'data': {'name': 'CreateComputePipeline', 'children': [
                    leaf('InlineShaderID', 30), leaf('pPipelineState', 40),
                    {'name': 'pDesc', 'children': [leaf('pRootSignature', 20)]}]}}],
                'candidates': [{'pipeline': 40, 'rootSignature': 20, 'groups': [320, 172, 1],
                                'chunkIndex': 1000, 'commandList': 70, 'arguments': arguments}]}
    bound = {'phase': 'complete', 'shader': 'ResourceId::30', 'capture': 'fixture.rdc', 'event': 9,
             'reflection': {'readOnlyResources': resources}, 'bindings': bindings,
             'constantBlocks': [{'index': 0, 'name': 'bufferdata', 'byteSize': 272}]}
    return recorded, layout, bound, blobs


class ClusterComputeContract(unittest.TestCase):
    def test_valid_fixture_pins_only_offline_contract(self):
        result = build_contract(*fixture())
        self.assertEqual([v['register'] for v in result['directBuffers']], [2, 3, 4, 15])
        self.assertEqual(result['textureTable']['shadowAtlasTableOffset'], 14)
        self.assertFalse(result['runtimeBindingEstablished'])
        self.assertFalse(result['captureIdsAreRuntimeIdentifiers'])
        self.assertFalse(result['safeAttachEstablished'])

    def test_shifted_register_or_gap_table_offset_refused(self):
        for parameter, field, value in [(3, 'register', 5), (4, 'type', 0)]:
            _, layout, _, _ = fixture()
            layout['parameters'][parameter][field] = value
            with self.assertRaises(ValueError):
                validate_root(layout)
        _, layout, _, _ = fixture()
        layout['parameters'][5]['ranges'][1]['tableOffset'] = 2
        with self.assertRaises(ValueError):
            validate_root(layout)

    def test_modified_binary_and_detached_sdk_report_refused(self):
        recorded, layout, bound, blobs = fixture()
        blobs['computeShader'] += b'changed'
        with self.assertRaises(ValueError):
            build_contract(recorded, layout, bound, blobs)
        recorded, layout, bound, blobs = fixture()
        layout['inputSha256'] = '0' * 64
        with self.assertRaises(ValueError):
            build_contract(recorded, layout, bound, blobs)

    def test_root_srv_cannot_be_replaced_by_table_binding(self):
        recorded, layout, bound, blobs = fixture()
        recorded['candidates'][0]['arguments']['3']['data']['name'] = 'SetComputeRootDescriptorTable'
        with self.assertRaises(ValueError):
            build_contract(recorded, layout, bound, blobs)

    def test_wrong_buffer_or_camera_offset_refused(self):
        for index, field, value in [(2, 'resource', 'ResourceId::999'), (4, 'byteOffset', 512)]:
            recorded, layout, bound, blobs = fixture()
            bound['bindings'][index][field] = value
            with self.assertRaises(ValueError):
                build_contract(recorded, layout, bound, blobs)

    def test_ambiguous_pipeline_or_candidate_refused(self):
        for key in ('creations', 'candidates'):
            recorded, layout, bound, blobs = fixture()
            recorded[key].append(copy.deepcopy(recorded[key][0]))
            with self.assertRaises(ValueError):
                build_contract(recorded, layout, bound, blobs)

    def test_camera_block_or_shader_identity_mismatch_refused(self):
        for field, value in [('shader', 'ResourceId::999'), ('constantBlocks', [])]:
            recorded, layout, bound, blobs = fixture()
            bound[field] = value
            with self.assertRaises(ValueError):
                build_contract(recorded, layout, bound, blobs)


if __name__ == '__main__':
    unittest.main()
