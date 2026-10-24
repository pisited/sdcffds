"""Pin the captured clustered compute ABI offline; does not install a bridge."""
import argparse
import hashlib
import json
from pathlib import Path


EXPECTED_PARAMETERS = [
    {'index': 0, 'type': 2, 'visibility': 0, 'register': 0, 'space': 0},
    *[{'index': i, 'type': 3, 'visibility': 0, 'register': register, 'space': 0}
      for i, register in enumerate((2, 3, 4, 15), 1)],
    {'index': 5, 'type': 0, 'visibility': 0, 'ranges': [
        {'type': 0, 'count': 2, 'baseRegister': 0, 'space': 0, 'tableOffset': 0},
        {'type': 0, 'count': 9, 'baseRegister': 6, 'space': 0, 'tableOffset': 6}]},
    {'index': 6, 'type': 0, 'visibility': 0, 'ranges': [
        {'type': 1, 'count': 1, 'baseRegister': 0, 'space': 0, 'tableOffset': 0}]},
    {'index': 7, 'type': 0, 'visibility': 0, 'ranges': [
        {'type': 3, 'count': 2, 'baseRegister': 0, 'space': 0, 'tableOffset': 0}]}]


def validate_root(layout):
    if (layout.get('sdkDeserialized') is not True or layout.get('gpuDeviceCreated') is not False or
            layout.get('version') != '1.0' or layout.get('flags') != 0 or
            layout.get('staticSamplerCount') != 0 or layout.get('parameters') != EXPECTED_PARAMETERS):
        raise ValueError('Captured SDK root layout differs from the confirmed clustered compute ABI')


def children(node):
    values = node.get('children', [])
    if len({v['name'] for v in values}) != len(values):
        raise ValueError('Ambiguous serialized fields')
    return {v['name']: v for v in values}


def build_contract(recorded, layout, bound, blobs):
    validate_root(layout)
    if recorded.get('phase') != 'complete' or recorded.get('gpuReplayOpened') is not False:
        raise ValueError('Require completed CPU-only recording analysis')
    if bound.get('phase') != 'complete' or bound.get('error'):
        raise ValueError('Require completed dispatch binding evidence')
    pins = {p['kind']: p for p in recorded['pinnedBlobs']}
    if set(pins) != {'computeShader', 'rootSignature'} or set(blobs) != set(pins):
        raise ValueError('Require exactly one shader and root blob')
    for kind, pin in pins.items():
        raw = blobs[kind]
        if not 0 < len(raw) <= 262144 or len(raw) != pin['bytes'] or hashlib.sha256(raw).hexdigest() != pin['sha256']:
            raise ValueError('Pinned binary length/hash mismatch: ' + kind)
    if layout.get('inputSha256') != pins['rootSignature']['sha256'] or layout.get('inputBytes') != pins['rootSignature']['bytes']:
        raise ValueError('SDK layout report is not tied to the pinned root binary')
    root_id, shader_id = pins['rootSignature']['resource'], pins['computeShader']['resource']
    if bound['shader'] != 'ResourceId::' + str(shader_id):
        raise ValueError('Captured shader identity mismatch')
    pipelines = []
    for creation in recorded['creations']:
        node = creation['data']
        if node['name'].endswith('CreateComputePipeline'):
            fields = children(node)
            if fields['InlineShaderID']['value'] == shader_id:
                if children(fields['pDesc'])['pRootSignature']['value'] != root_id:
                    raise ValueError('Captured pipeline uses a different root signature')
                pipelines.append(fields['pPipelineState']['value'])
    if len(pipelines) != 1:
        raise ValueError('Ambiguous shader-to-pipeline creation identity')
    candidates = [c for c in recorded['candidates'] if c['pipeline'] == pipelines[0] and c['rootSignature'] == root_id]
    if len(candidates) != 1:
        raise ValueError('Require one recorded candidate for the pinned pass')
    candidate = candidates[0]
    if candidate['groups'] != [320, 172, 1]:
        raise ValueError('Unexpected captured dispatch dimensions; not a generic runtime identity')
    resources = {r['name']: r for r in bound['reflection']['readOnlyResources']}
    direct = []
    for parameter, name in ((1, 'clusterGrid'), (2, 'clusterLightIndices'), (3, 'clusterLights'), (4, 'shadowViews')):
        reflection = resources[name]
        matches = [d for d in bound['bindings'] if d['type'] == 'DescriptorType.Buffer' and d['index'] == reflection['index']]
        if len(matches) != 1:
            raise ValueError('Ambiguous captured buffer: ' + name)
        argument = candidate['arguments'][str(parameter)]['data']
        if not argument['name'].endswith('SetComputeRootShaderResourceView'):
            raise ValueError('Expected direct compute root SRV, not a descriptor table')
        fields = children(argument)
        location = children(fields['BufferLocation'])
        if (fields['RootParameterIndex']['value'] != parameter or
                matches[0]['resource'] != 'ResourceId::' + str(location['Buffer']['value']) or
                matches[0]['byteOffset'] != location['Offset']['value'] or
                reflection['bindNumber'] != EXPECTED_PARAMETERS[parameter]['register']):
            raise ValueError('Recorded root address differs from dispatch reflection/binding: ' + name)
        direct.append({'parameter': parameter, 'name': name, 'register': reflection['bindNumber'],
                       'captureResource': matches[0]['resource'], 'byteOffset': matches[0]['byteOffset']})
    cbvs = [d for d in bound['bindings'] if d['type'] == 'DescriptorType.ConstantBuffer' and d['index'] == 0]
    if bound.get('constantBlocks') != [{'index': 0, 'name': 'bufferdata', 'byteSize': 272}]:
        raise ValueError('Unexpected captured camera constant-block layout')
    cbv = candidate['arguments']['0']['data']
    location = children(children(cbv)['BufferLocation'])
    if (not cbv['name'].endswith('SetComputeRootConstantBufferView') or
            children(cbv)['RootParameterIndex']['value'] != 0 or len(cbvs) != 1 or
            cbvs[0]['resource'] != 'ResourceId::' + str(location['Buffer']['value']) or
            cbvs[0]['byteOffset'] != location['Offset']['value']):
        raise ValueError('Camera constant-block root binding mismatch')
    return {'schema': 'beamrt.cluster.compute-contract.v1', 'capture': bound['capture'],
            'captureEvent': bound['event'], 'captureChunk': candidate['chunkIndex'],
            'captureCommandList': candidate['commandList'], 'capturePipeline': pipelines[0],
            'shaderSha256': pins['computeShader']['sha256'], 'shaderBytes': pins['computeShader']['bytes'],
            'rootSha256': pins['rootSignature']['sha256'], 'rootBytes': pins['rootSignature']['bytes'],
            'rootParameters': EXPECTED_PARAMETERS, 'directBuffers': direct,
            'cameraConstants': {'parameter': 0, 'register': 0, 'captureResource': cbvs[0]['resource'],
                                'byteOffset': cbvs[0]['byteOffset'], 'reflectedBytes': 272},
            'textureTable': {'parameter': 5, 'shadowAtlasRegister': 14, 'shadowAtlasTableOffset': 14},
            'outputTable': {'parameter': 6, 'register': 0, 'tableOffset': 0},
            'samplerTable': {'parameter': 7, 'count': 2},
            'captureIdsAreRuntimeIdentifiers': False, 'runtimeBindingEstablished': False,
            'safeAttachEstablished': False, 'gpuOrderingVerified': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture_directory', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.capture_directory.resolve()
    read = lambda name: json.loads((root / name).read_text(encoding='utf8'))
    recorded = read('cluster-compute-contract.json')
    blobs = {}
    for pin in recorded['pinnedBlobs']:
        path = Path(pin['path']).resolve()
        if path.parent != root:
            raise ValueError('Pinned binary must be in the capture directory')
        blobs[pin['kind']] = path.read_bytes()
    result = build_contract(recorded, read('cluster-root-sdk-layout.json'), read('cluster-dispatch-22811.json'), blobs)
    args.output.write_text(json.dumps(result, indent=2), encoding='utf8')
    print('Pinned compute ABI; four direct buffers verified. No runtime bridge installed.')


if __name__ == '__main__':
    main()
