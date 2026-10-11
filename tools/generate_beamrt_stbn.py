#!/usr/bin/env python3
"""Generate BeamRT's reproducible 2D+time sampling atlas.

This is an independent spectral alternating-projection generator.  It does not
copy NVIDIA STBN source or pregenerated textures.  The design target follows
the published STBN property: every XY frame suppresses low spatial frequencies
and every fixed XY pixel suppresses low temporal frequencies.

The output packs 64 128x128 RG slices into an 8x8 1024x1024 PNG and a legacy
uncompressed RGB32 DDS, stored as B,G,R,X.  R selects the cosine-hemisphere radius and G selects
azimuth.  BeamRT samples the DDS as linear UNORM data, point-filtered.

This is an STBN candidate, not validated directional STBN.  Spectral metrics on
scalar channels do not establish the distribution of the mapped directions.
Repacking an existing DDS changes its container and storage channel order only,
not its decoded RGB samples or sampling quality.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path

import numpy as np
from PIL import Image


def smoothstep(edge0: float, edge1: float, value: np.ndarray) -> np.ndarray:
    t = np.clip((value - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def rank_spatial(values: np.ndarray) -> np.ndarray:
    frames, height, width = values.shape
    flat = values.reshape(frames, height * width)
    order = np.argsort(flat, axis=1, kind="stable")
    ranks = np.empty_like(order, dtype=np.int32)
    rank_values = np.broadcast_to(np.arange(height * width, dtype=np.int32), order.shape)
    np.put_along_axis(ranks, order, rank_values, axis=1)
    return ((ranks.astype(np.float32) + 0.5) / float(height * width)).reshape(values.shape)


def rank_temporal(values: np.ndarray) -> np.ndarray:
    frames = values.shape[0]
    order = np.argsort(values, axis=0, kind="stable")
    ranks = np.empty_like(order, dtype=np.int16)
    rank_values = np.broadcast_to(
        np.arange(frames, dtype=np.int16)[:, None, None], order.shape
    )
    np.put_along_axis(ranks, order, rank_values, axis=0)
    return (ranks.astype(np.float32) + 0.5) / float(frames)


def spatial_highpass(values: np.ndarray, gain: np.ndarray) -> np.ndarray:
    spectrum = np.fft.fft2(values - values.mean(axis=(1, 2), keepdims=True), axes=(1, 2))
    spectrum *= gain[None, :, :]
    return np.fft.ifft2(spectrum, axes=(1, 2)).real.astype(np.float32)


def temporal_highpass(values: np.ndarray, gain: np.ndarray) -> np.ndarray:
    spectrum = np.fft.fft(values - values.mean(axis=0, keepdims=True), axis=0)
    spectrum *= gain[:, None, None]
    return np.fft.ifft(spectrum, axis=0).real.astype(np.float32)


def normalize_standard(values: np.ndarray) -> np.ndarray:
    deviation = float(values.std())
    if deviation < 1.0e-8:
        return values
    return (values - float(values.mean())) / deviation


def generate_channel(size: int, frames: int, iterations: int, seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    values = rng.random((frames, size, size), dtype=np.float32)

    frequency = np.fft.fftfreq(size)
    fy, fx = np.meshgrid(frequency, frequency, indexing="ij")
    spatial_radius = np.sqrt(fx * fx + fy * fy)
    spatial_gain = smoothstep(0.025, 0.18, spatial_radius).astype(np.float32)
    spatial_gain[0, 0] = 0.0

    temporal_frequency = np.abs(np.fft.fftfreq(frames))
    temporal_gain = smoothstep(0.035, 0.28, temporal_frequency).astype(np.float32)
    temporal_gain[0] = 0.0

    for iteration in range(iterations):
        spatial = normalize_standard(spatial_highpass(values, spatial_gain))
        temporal = normalize_standard(temporal_highpass(values, temporal_gain))

        # Spatial quality has slightly higher weight because motion destroys
        # temporal correspondence, while every rendered frame still needs a
        # well-distributed image-space pattern.
        values = 0.62 * spatial + 0.38 * temporal
        values = rank_spatial(values)

        # Pull each pixel toward a cyclically useful temporal ordering without
        # fully erasing the just-created spatial spectrum.
        temporal_rank = rank_temporal(values)
        blend = 0.34 + 0.12 * ((iteration + 1) / float(iterations))
        values = (1.0 - blend) * values + blend * temporal_rank

    # Finish on a spatial rank projection: every frame has an exact uniform
    # histogram, which is important for unbiased cosine-hemisphere sampling.
    return rank_spatial(0.72 * values + 0.28 * spatial_highpass(values, spatial_gain))


def spectral_metrics(values: np.ndarray) -> dict[str, float]:
    centered = values - values.mean(axis=(1, 2), keepdims=True)
    spatial_power = np.abs(np.fft.fft2(centered, axes=(1, 2))) ** 2
    size = values.shape[1]
    frequency = np.fft.fftfreq(size)
    fy, fx = np.meshgrid(frequency, frequency, indexing="ij")
    radius = np.sqrt(fx * fx + fy * fy)
    spatial_low = (radius > 0.0) & (radius < 0.08)
    spatial_mid = (radius >= 0.08) & (radius < 0.35)

    temporal_centered = values - values.mean(axis=0, keepdims=True)
    temporal_power = np.abs(np.fft.fft(temporal_centered, axis=0)) ** 2
    temporal_frequency = np.abs(np.fft.fftfreq(values.shape[0]))
    temporal_low = (temporal_frequency > 0.0) & (temporal_frequency < 0.13)
    temporal_mid = (temporal_frequency >= 0.13) & (temporal_frequency < 0.45)

    return {
        "mean": float(values.mean()),
        "stddev": float(values.std()),
        "spatial_low_to_mid_power": float(
            spatial_power[:, spatial_low].mean() / max(spatial_power[:, spatial_mid].mean(), 1.0e-12)
        ),
        "temporal_low_to_mid_power": float(
            temporal_power[temporal_low].mean() / max(temporal_power[temporal_mid].mean(), 1.0e-12)
        ),
    }


def pack_atlas(red: np.ndarray, green: np.ndarray) -> np.ndarray:
    frames, size, _ = red.shape
    tiles = int(round(frames ** 0.5))
    if tiles * tiles != frames:
        raise ValueError("frame count must be a square for the packed atlas")
    atlas = np.zeros((size * tiles, size * tiles, 4), dtype=np.uint8)
    atlas[:, :, 3] = 255
    for frame in range(frames):
        tile_x = frame % tiles
        tile_y = frame // tiles
        y0 = tile_y * size
        x0 = tile_x * size
        atlas[y0 : y0 + size, x0 : x0 + size, 0] = np.round(red[frame] * 255.0).astype(np.uint8)
        atlas[y0 : y0 + size, x0 : x0 + size, 1] = np.round(green[frame] * 255.0).astype(np.uint8)
    return atlas


DDS_REQUIRED_FLAGS = 0x1 | 0x2 | 0x4 | 0x8 | 0x1000
DDS_LEGACY_RGB_FLAGS = 0x1 | 0x2 | 0x4 | 0x1000
DDS_CAPS_TEXTURE = 0x1000
DDPF_FOURCC = 0x4
DDPF_RGB = 0x40
RGB32_MASKS = (0x00FF0000, 0x0000FF00, 0x000000FF, 0)


def legacy_dds_rgb32_bytes(width: int, height: int, rgba_payload: bytes) -> bytes:
    """Encode logical R,G,B,A samples as a single-level B,G,R,X RGB32 DDS.

    Match BeamNG's shipped AreaMap33.dds header, except image dimensions.
    Its DDPF_RGB format has no alpha flag/mask, pitch flag/value, or DX10
    extension.  The masks recover logical R/G/B from little-endian B/G/R/X
    storage; X is 255.  No sampling, UNORM, or gamma conversion occurs.
    """
    if width <= 0 or height <= 0 or width * 4 > 0xFFFFFFFF or height > 0xFFFFFFFF:
        raise ValueError("DDS output dimensions must be positive uint32 values")
    if len(rgba_payload) != width * height * 4:
        raise ValueError("DDS output payload must contain exactly width*height*4 bytes")

    rgba = np.frombuffer(rgba_payload, dtype=np.uint8).reshape(height, width, 4)
    bgrx = np.empty_like(rgba)
    bgrx[:, :, 0] = rgba[:, :, 2]
    bgrx[:, :, 1] = rgba[:, :, 1]
    bgrx[:, :, 2] = rgba[:, :, 0]
    bgrx[:, :, 3] = 255

    header = b"DDS " + struct.pack(
        "<7I11I",
        124,
        DDS_LEGACY_RGB_FLAGS,
        height,
        width,
        0,
        0,
        0,
        *([0] * 11),
    )
    header += struct.pack("<8I", 32, DDPF_RGB, 0, 32, *RGB32_MASKS)
    header += struct.pack("<5I", DDS_CAPS_TEXTURE, 0, 0, 0, 0)
    return header + bgrx.tobytes(order="C")


def write_dds_rgb32(path: Path, rgba: np.ndarray) -> None:
    """Write logical RGBA input as linear UNORM RGB32 with B,G,R,X storage."""
    if rgba.ndim != 3 or rgba.shape[2] != 4 or rgba.dtype != np.uint8:
        raise ValueError("DDS output expects uint8 RGBA")
    height, width, _ = rgba.shape
    data = legacy_dds_rgb32_bytes(width, height, rgba.tobytes(order="C"))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def parse_dx10_rgba8_dds(data: bytes) -> tuple[int, int, bytes]:
    """Accept only tightly packed, linear RGBA8 DX10 DDS with one 2D image.

    Reject alternate formats, mip chains, arrays, volumes, cubes, and length
    mismatches instead of interpreting or silently discarding their bytes.
    """
    if len(data) < 148 or data[:4] != b"DDS ":
        raise ValueError("repack input requires a complete 148-byte DX10 DDS header")
    header = struct.unpack("<31I", data[4:128])
    if header[0] != 124 or header[18] != 32:
        raise ValueError("repack input has invalid DDS header or pixel-format size")
    if header[1] != DDS_REQUIRED_FLAGS:
        raise ValueError("repack input must declare only caps, width, height, pitch, pixel format")
    if header[19] != DDPF_FOURCC or data[84:88] != b"DX10" or any(header[21:26]):
        raise ValueError("repack input must use an unambiguous DX10 pixel format")
    height, width, pitch, depth, mip_count = header[2:7]
    if width == 0 or height == 0 or pitch != width * 4:
        raise ValueError("repack input requires positive dimensions and a width*4 row pitch")
    if depth != 0 or mip_count not in (0, 1) or header[26:] != (DDS_CAPS_TEXTURE, 0, 0, 0, 0):
        raise ValueError("repack input must be a single 2D texture without mips, volume, or cube caps")
    dxgi_format, dimension, misc_flag, array_size, alpha_mode = struct.unpack("<5I", data[128:148])
    if dxgi_format != 28 or dimension != 3 or array_size != 1 or misc_flag != 0:
        raise ValueError("repack input must be R8G8B8A8_UNORM (28), TEXTURE2D (3), array size 1")
    if alpha_mode not in (0, 1):
        raise ValueError("repack input alpha must be unknown or straight, not premultiplied/custom")
    payload = data[148:]
    if len(payload) != width * height * 4:
        raise ValueError("repack input payload must contain exactly width*height*4 bytes")
    return width, height, payload


def repack_dx10_rgba8_dds(input_path: Path, output_path: Path) -> dict[str, int | str]:
    """Convert DDS packing without regenerating noise or overwriting input.

    The output must be a new file, so repeat conversion cannot accidentally
    replace the original atlas or an existing rollback artifact.
    """
    if input_path.resolve() == output_path.resolve():
        raise ValueError("repack output must differ from its input")
    width, height, payload = parse_dx10_rgba8_dds(input_path.read_bytes())
    data = legacy_dds_rgb32_bytes(width, height, payload)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("xb") as stream:
        stream.write(data)
    return {
        "operation": "DX10 RGBA8_UNORM to native-header legacy RGB32 BGRX packing; decoded RGB preserved",
        "width": width,
        "height": height,
        "payload_bytes": len(payload),
        "source_rgba_payload_sha256": hashlib.sha256(payload).hexdigest(),
        "storage_bgrx_payload_sha256": hashlib.sha256(data[128:]).hexdigest(),
        "dds_bytes": len(data),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, help="PNG output for newly generated noise")
    parser.add_argument("--dds-output", type=Path)
    parser.add_argument("--repack", type=Path, help="existing DX10 linear RGBA8 DDS; preserve decoded RGB in RGB32 BGRX storage")
    parser.add_argument("--metrics", type=Path)
    parser.add_argument("--size", type=int, default=128)
    parser.add_argument("--frames", type=int, default=64)
    parser.add_argument("--iterations", type=int, default=10)
    parser.add_argument("--seed", type=int, default=0xBEA47)
    args = parser.parse_args()

    if args.repack:
        if not args.dds_output or args.output or args.metrics:
            parser.error("--repack requires --dds-output and cannot use --output or --metrics")
        try:
            report = repack_dx10_rgba8_dds(args.repack, args.dds_output)
        except (OSError, ValueError) as error:
            parser.error(str(error))
        print(json.dumps(report, indent=2))
        return
    if not args.output:
        parser.error("generation requires --output (or use --repack with --dds-output)")

    red = generate_channel(args.size, args.frames, args.iterations, args.seed)
    green = generate_channel(args.size, args.frames, args.iterations, args.seed ^ 0x9E3779B9)
    atlas = pack_atlas(red, green)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(atlas, mode="RGBA").save(args.output, optimize=True)
    dds_output = args.dds_output or args.output.with_suffix(".dds")
    write_dds_rgb32(dds_output, atlas)

    report = {
        "generator": "BeamRT spectral alternating projection STBN candidate",
        "directional_stbn_validated": False,
        "dds_format": "legacy uncompressed linear UNORM RGB32 BGRX, native header, one 2D level",
        "layout": f"{args.frames} frames of {args.size}x{args.size}, packed 8x8 RG",
        "iterations": args.iterations,
        "seed": args.seed,
        "red": spectral_metrics(red),
        "green": spectral_metrics(green),
        "channel_correlation": float(np.corrcoef(red.ravel(), green.ravel())[0, 1]),
    }
    print(json.dumps(report, indent=2))
    if args.metrics:
        args.metrics.parent.mkdir(parents=True, exist_ok=True)
        args.metrics.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
