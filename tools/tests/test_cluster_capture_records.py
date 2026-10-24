"""Offline captured-buffer decoding; no GPU or game process required."""
import base64
import hashlib
import math
import struct
import unittest

from tools.beamrt_cluster_capture_records import (
    LIGHT_FIELDS, VIEW_FIELDS, decode, decode_records, payload_bytes, read_value, spot_projection_checks)


def kind(count=1, base='VarType.Float', matrix=False, row_major=False):
    return {'name': 'float4x4' if matrix else 'float', 'baseType': base,
            'rows': 4 if matrix else 1, 'columns': 4 if matrix else count,
            'elements': 1, 'arrayByteStride': 64 if matrix else count * 4,
            'matrixByteStride': 16 if matrix else count * 4,
            'rowMajor': row_major if matrix else True, 'members': []}


def record_kind(name, fields):
    return {'name': name, 'elements': 1, 'members': [
        {'name': name, 'byteOffset': offset, 'type': kind(count, matrix=count == 16)}
        for name, offset, count in fields]}


def payload(raw):
    return {'encoding': 'base64', 'byteLength': len(raw),
            'sha256': hashlib.sha256(raw).hexdigest(),
            'data': base64.b64encode(raw).decode('ascii')}


def fixture():
    lights = bytearray(160)
    struct.pack_into('<f', lights, 72, 6)
    struct.pack_into('<f', lights, 88, 1)
    views = bytearray(80 * 6)
    for index in range(6):
        struct.pack_into('<4f', views, index * 80, .125, .125, (index % 4) * .125, (index // 4) * .125)
    identity = [int(r == c) for c in range(4) for r in range(4)]
    constants = struct.pack('<i32f', 0, *identity, *identity)
    return {'schema': 'beamrt.capture.cluster-records.v1', 'phase': 'complete',
            'selectedEventRestored': True, 'capture': 'fixture.rdc', 'event': 22811,
            'shader': 'fixture', 'reflection': {
                'resources': [{'name': 'clusterLights', 'type': record_kind('ClusterLight', LIGHT_FIELDS)},
                              {'name': 'shadowViews', 'type': record_kind('ShadowView', VIEW_FIELDS)}],
                'constantBlocks': [{'name': 'bufferdata', 'byteSize': len(constants), 'variables': [
                    {'name': 'disableShadows', 'byteOffset': 0, 'type': kind(base='VarType.SInt')},
                    {'name': 'invView', 'byteOffset': 4, 'type': kind(matrix=True)},
                    {'name': 'viewMatrix', 'byteOffset': 68, 'type': kind(matrix=True)}]}]},
            'payloads': {'clusterLights': payload(lights), 'shadowViews': payload(views),
                         'bufferdata': payload(constants)}}


class ClusterCaptureRecords(unittest.TestCase):
    def test_complete_fixture_is_decoded_without_runtime_claim(self):
        result = decode(fixture())
        self.assertEqual((result['lightRecordCount'], result['shadowViewRecordCount'], result['lightsWithViews']), (1, 6, 1))
        self.assertEqual(result['viewInverseMaxError'], 0)
        self.assertEqual(result['constants']['disableShadows'], 0)
        self.assertFalse(result['runtimeBindingEstablished'])
        self.assertFalse(result['atlasDepthContentsVerified'])

    def test_partial_or_failed_restore_refused(self):
        for key, value in [('phase', 'restoring_selection'), ('selectedEventRestored', False)]:
            doc = fixture()
            doc[key] = value
            with self.assertRaises(ValueError):
                decode(doc)

    def test_separate_replay_requires_successful_owned_shutdown(self):
        doc = fixture()
        del doc['selectedEventRestored']
        doc.update(ownsReplay=True, existingUISessionModified=False, replayShutdownSucceeded=True)
        self.assertEqual(decode(doc)['lightRecordCount'], 1)
        doc['replayShutdownSucceeded'] = False
        with self.assertRaises(ValueError):
            decode(doc)
        doc.update(replayShutdownSucceeded=True, existingUISessionModified=True)
        with self.assertRaises(ValueError):
            decode(doc)

    def test_recorded_upload_source_does_not_claim_gpu_readback(self):
        doc = fixture()
        del doc['selectedEventRestored']
        doc.update(dataSource='recorded_uploads', gpuReplayOpened=False,
                   gpuReadbackVerified=False, recordedUploadExtractionComplete=True,
                   uploadSubmissionOrderVerified=True)
        result = decode(doc)
        self.assertEqual(result['dataSource'], 'recorded_uploads')
        self.assertFalse(result['gpuReadbackVerified'])
        doc['uploadSubmissionOrderVerified'] = False
        doc['selectedEventRestored'] = True
        with self.assertRaises(ValueError):
            decode(doc)

    def test_spot_axis_projected_from_world_position(self):
        light = {'index': 0, 'lightType': 1, 'shadowType': 0, 'shadowViewCount': 1,
                 'shadowViewOffset': 0, 'positionWS': [10, 20, 30], 'directionWS': [0, 0, -1]}
        view = {'worldToLightProj': [[1, 0, 0, -10], [0, 1, 0, -20], [0, 0, 0, .5], [0, 0, -1, 30]]}
        result = spot_projection_checks([light], [view])[0]
        self.assertTrue(result['worldSpaceProjectionConsistent'])
        self.assertTrue(result['depthDecreasesAlongAxis'])
        view['worldToLightProj'][0][3] = 0
        self.assertFalse(spot_projection_checks([light], [view])[0]['worldSpaceProjectionConsistent'])

    def test_wrong_way_spot_projection_is_not_certified(self):
        light = {'index': 0, 'lightType': 1, 'shadowType': 0, 'shadowViewCount': 1,
                 'shadowViewOffset': 0, 'positionWS': [0, 0, 0], 'directionWS': [0, 0, 1]}
        view = {'worldToLightProj': [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 0, .5], [0, 0, -1, 0]]}
        self.assertFalse(spot_projection_checks([light], [view])[0]['worldSpaceProjectionConsistent'])

    def test_hash_and_length_mismatch_refused(self):
        for key, value in [('sha256', '0' * 64), ('byteLength', 3), ('data', '!invalid!')]:
            p = payload(b'1234')
            p[key] = value
            with self.assertRaises(ValueError):
                payload_bytes(p)

    def test_column_major_matrix_is_transposed_to_mathematical_rows(self):
        raw = struct.pack('<16f', *range(16))
        self.assertEqual(read_value(raw, 0, kind(matrix=True))[1], [1, 5, 9, 13])
        self.assertEqual(read_value(raw, 0, kind(matrix=True, row_major=True))[1], [4, 5, 6, 7])

    def test_padded_matrix_stride_respected(self):
        t = kind(matrix=True)
        t['matrixByteStride'] = 32
        raw = b''.join(struct.pack('<4f', *(c * 4 + r for r in range(4))) + bytes(16) for c in range(4))
        self.assertEqual(read_value(raw, 0, t)[2], [2, 6, 10, 14])

    def test_truncated_nonfinite_and_unsupported_values_refused(self):
        for raw, t in [(b'1', kind()), (struct.pack('<f', math.nan), kind()),
                       (struct.pack('<f', math.inf), kind()), (b'1234', kind(base='VarType.Double'))]:
            with self.assertRaises(ValueError):
                read_value(raw, 0, t)

    def test_reflected_offsets_not_guessed(self):
        t = record_kind('ShadowView', VIEW_FIELDS)
        t['members'][1]['byteOffset'] = 12
        with self.assertRaises(ValueError):
            decode_records(bytes(80), t, VIEW_FIELDS, 80)

    def test_nonintegral_and_out_of_range_shadow_views_refused(self):
        for count, offset in [(1.5, 0), (6, 1), (7, 0), (-1, 0)]:
            doc = fixture()
            raw = bytearray(payload_bytes(doc['payloads']['clusterLights']))
            struct.pack_into('<2f', raw, 68, offset, count)
            doc['payloads']['clusterLights'] = payload(raw)
            with self.assertRaises(ValueError):
                decode(doc)

    def test_invalid_atlas_rectangle_refused(self):
        doc = fixture()
        raw = bytearray(payload_bytes(doc['payloads']['shadowViews']))
        struct.pack_into('<4f', raw, 0, .5, .5, .75, .75)
        doc['payloads']['shadowViews'] = payload(raw)
        with self.assertRaises(ValueError):
            decode(doc)

    def test_zero_camera_is_not_certified_as_no_shadows(self):
        doc = fixture()
        doc['payloads']['bufferdata'] = payload(bytes(doc['payloads']['bufferdata']['byteLength']))
        with self.assertRaisesRegex(ValueError, 'Invalid camera constants'):
            decode(doc)

    def test_unreferenced_placeholder_not_certified(self):
        doc = fixture()
        raw = payload_bytes(doc['payloads']['shadowViews']) + bytes(80)
        doc['payloads']['shadowViews'] = payload(raw)
        result = decode(doc)
        self.assertEqual(result['shadowViewRecordCount'], 7)
        self.assertNotIn(6, result['referencedViewIndices'])


if __name__ == '__main__':
    unittest.main()
