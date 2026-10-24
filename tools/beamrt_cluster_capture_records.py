"""Decode bounded RenderDoc cluster readbacks offline; never connects to a game.

Record strides are an explicit installed-BeamNG ABI hypothesis, checked against
captured reflection and record consistency, not inferred from buffer length or
descriptor elementByteSize. This does not establish a live mod binding route.
"""
import argparse
import base64
import hashlib
import json
import math
from pathlib import Path
import struct


LIGHT_FIELDS = (
    ('positionWS', 0, 3), ('invRadius', 12, 1), ('directionWS', 16, 3),
    ('invRadiusSq', 28, 1), ('color', 32, 4), ('spotCosOuter', 48, 1),
    ('spotInvFalloff', 52, 1), ('lightType', 56, 1), ('cookieIndex', 60, 1),
    ('shadowType', 64, 1), ('shadowViewOffset', 68, 1), ('shadowViewCount', 72, 1),
    ('sourceRadius', 76, 1), ('shadowSoftness', 80, 1), ('shadowTexelSize', 84, 1),
    ('shadowStrength', 88, 1), ('ownerId', 92, 1), ('worldToLightProj', 96, 16))
VIEW_FIELDS = (('atlasRect', 0, 4), ('worldToLightProj', 16, 16))


def payload_bytes(payload):
    if payload.get('encoding') != 'base64' or not 0 < payload['byteLength'] <= 262144:
        raise ValueError('Unsupported payload encoding/length')
    raw = base64.b64decode(payload['data'], validate=True)
    if len(raw) != payload['byteLength'] or hashlib.sha256(raw).hexdigest() != payload['sha256']:
        raise ValueError('Payload length/hash mismatch')
    return raw


def read_value(raw, offset, kind):
    if kind['elements'] != 1 or kind['members']:
        raise ValueError('Unsupported array/struct value')
    rows, columns = kind['rows'], kind['columns']
    if rows not in range(1, 5) or columns not in range(1, 5):
        raise ValueError('Unsupported value shape')
    code = {'VarType.Float': 'f', 'VarType.UInt': 'I', 'VarType.SInt': 'i'}.get(kind['baseType'])
    if code is None:
        raise ValueError('Unsupported scalar type')
    matrix = rows > 1 and columns > 1
    row_major = kind['rowMajor']
    stride = kind['matrixByteStride'] if matrix else 0
    if matrix and stride < 4 * (columns if row_major else rows):
        raise ValueError('Invalid matrix stride')
    values = []
    for row in range(rows):
        line = []
        for column in range(columns):
            index = ((row * stride + column * 4) if row_major else
                     (column * stride + row * 4)) if matrix else (row * columns + column) * 4
            address = offset + index
            if address < 0 or address + 4 > len(raw):
                raise ValueError('Value outside payload')
            value = struct.unpack_from('<' + code, raw, address)[0]
            if isinstance(value, float) and not math.isfinite(value):
                raise ValueError('Nonfinite captured value')
            line.append(value)
        values.append(line)
    return values if matrix else (values[0][0] if rows * columns == 1 else sum(values, []))


def decode_records(raw, kind, fields, stride):
    members = kind['members']
    if kind['name'] not in ('ClusterLight', 'ShadowView') or kind['elements'] != 1:
        raise ValueError('Unexpected record type')
    if len(members) != len(fields) or len(raw) % stride:
        raise ValueError('Record layout or byte-length mismatch')
    for member, (name, offset, count) in zip(members, fields):
        t = member['type']
        if (member['name'], member['byteOffset'], t['baseType'], t['rows'] * t['columns']) != (
                name, offset, 'VarType.Float', count):
            raise ValueError('Captured reflection does not match installed ABI hypothesis: ' + name)
        if count == 16 and (t['rows'], t['columns'], t['matrixByteStride']) != (4, 4, 16):
            raise ValueError('Unexpected matrix layout')
    return [{m['name']: read_value(raw, base + m['byteOffset'], m['type']) for m in members}
            for base in range(0, len(raw), stride)]


def integer(value, name):
    if not math.isfinite(value) or value < 0 or value != int(value):
        raise ValueError('Invalid integer-valued float: ' + name)
    return int(value)


def spot_projection_checks(lights, views):
    """Algebraic world-space checks, not sampled shadow/depth evidence."""
    checks = []
    for light in lights:
        if light['lightType'] != 1 or light['shadowType'] != 0 or light['shadowViewCount'] != 1:
            continue
        matrix = views[int(light['shadowViewOffset'])]['worldToLightProj']

        def project(distance):
            point = [light['positionWS'][i] + distance * light['directionWS'][i] for i in range(3)] + [1]
            return [sum(matrix[r][k] * point[k] for k in range(4)) for r in range(4)]

        origin, near, far = project(0), project(1), project(2)
        forward = near[3] > 0 and far[3] > near[3]
        axis_error = max(abs(p[c] / p[3]) for p in (near, far) for c in (0, 1)) if forward else None
        checks.append({'lightIndex': light['index'], 'viewIndex': int(light['shadowViewOffset']),
                       'originClipW': origin[3], 'axisNdcXYMaxError': axis_error,
                       'forwardClipW': forward,
                       'depthDecreasesAlongAxis': forward and near[2] / near[3] > far[2] / far[3],
                       'worldSpaceProjectionConsistent': forward and abs(origin[3]) < .001 and axis_error < .001})
    return checks


def decode(document):
    if document.get('schema') != 'beamrt.capture.cluster-records.v1' or document.get('phase') != 'complete':
        raise ValueError('Require completed, versioned capture readback')
    ui_restored = document.get('selectedEventRestored') is True
    owned_closed = (document.get('ownsReplay') is True and
                    document.get('existingUISessionModified') is False and
                    document.get('replayShutdownSucceeded') is True)
    recorded_upload = (document.get('dataSource') == 'recorded_uploads' and
                       document.get('gpuReplayOpened') is False and
                       document.get('gpuReadbackVerified') is False and
                       document.get('recordedUploadExtractionComplete') is True and
                       document.get('uploadSubmissionOrderVerified') is True)
    source_is_upload = document.get('dataSource') == 'recorded_uploads'
    completion_valid = recorded_upload if source_is_upload else (ui_restored or owned_closed)
    if document.get('error') or not completion_valid:
        raise ValueError('Capture extraction/restore or owned replay shutdown was not successful')
    resources = {r['name']: r for r in document['reflection']['resources']}
    lights = decode_records(payload_bytes(document['payloads']['clusterLights']),
                            resources['clusterLights']['type'], LIGHT_FIELDS, 160)
    views = decode_records(payload_bytes(document['payloads']['shadowViews']),
                           resources['shadowViews']['type'], VIEW_FIELDS, 80)
    blocks = [b for b in document['reflection']['constantBlocks'] if b['name'] == 'bufferdata']
    if len(blocks) != 1:
        raise ValueError('Ambiguous constant block')
    raw_constants = payload_bytes(document['payloads']['bufferdata'])
    if len(raw_constants) != blocks[0]['byteSize']:
        raise ValueError('Constant block length mismatch')
    constants = {v['name']: read_value(raw_constants, v['byteOffset'], v['type'])
                 for v in blocks[0]['variables']}
    inv_view, view = constants['invView'], constants['viewMatrix']
    inverse_error = max(abs(sum(inv_view[r][k] * view[k][c] for k in range(4)) - int(r == c))
                        for r in range(4) for c in range(4))
    if inverse_error > .01:
        raise ValueError('Invalid camera constants: view/inverse-view product is not identity')
    selected = []
    referenced = set()
    for index, light in enumerate(lights):
        offset = integer(light['shadowViewOffset'], 'shadowViewOffset')
        count = integer(light['shadowViewCount'], 'shadowViewCount')
        if count and (count not in (1, 6) or offset + count > len(views)):
            raise ValueError('Shadow view range/type invalid at light ' + str(index))
        if count:
            selected.append({'index': index, **light})
            referenced.update(range(offset, offset + count))
    # Unreferenced allocation entries can be placeholders. They must not be
    # certified as valid views, nor invalidate a different light's real views.
    for index in referenced:
        view = views[index]
        sx, sy, ox, oy = view['atlasRect']
        if not (0 < sx <= 1 and 0 < sy <= 1 and 0 <= ox <= 1 - sx and 0 <= oy <= 1 - sy):
            raise ValueError('Shadow atlas rectangle outside atlas')
    return {'schema': 'beamrt.capture.cluster-decoded.v1', 'capture': document['capture'],
            'event': document['event'], 'shader': document['shader'],
            'dataSource': document.get('dataSource', 'gpu_replay_readback'),
            'gpuReadbackVerified': False if recorded_upload else None,
            'uploadSubmissionOrderVerified': recorded_upload,
            'layoutBasis': 'installed ABI hypothesis checked against captured member reflection',
            'recordStrideHypothesis': {'ClusterLight': 160, 'ShadowView': 80},
            'lightRecordCount': len(lights), 'shadowViewRecordCount': len(views),
            'lightsWithViews': len(selected), 'shadowedLights': selected,
            'referencedViewIndices': sorted(referenced),
            'views': views, 'constants': constants, 'viewInverseMaxError': inverse_error,
            'spotProjectionChecks': spot_projection_checks(selected, views),
            'runtimeBindingEstablished': False, 'atlasDepthContentsVerified': False,
            'offscreenCasterVerified': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = decode(json.loads(args.input.read_text(encoding='utf8')))
    args.output.write_text(json.dumps(result, indent=2, allow_nan=False), encoding='utf8')
    print(json.dumps({k: result[k] for k in ('lightRecordCount', 'shadowViewRecordCount',
                                           'lightsWithViews', 'viewInverseMaxError')}))


if __name__ == '__main__':
    main()
