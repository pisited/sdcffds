/**********************************************************************
Copyright (c) 2021 Advanced Micro Devices, Inc. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
********************************************************************/

// BeamRT fork: local MIT-licensed traversal core, initially mip 0 only.
// Engine private Hi-Z, indirect dispatch, wave retirement and sky history are
// NOT imported. The adapter supplies depth/normal/projection callbacks.
#ifndef FFX_SSSR
#define FFX_SSSR
#define FFX_SSSR_FLOAT_MAX                          3.402823466e+38

void FFX_SSSR_InitialAdvanceRay(float3 origin, float3 direction, float3 inv_direction, float2 current_mip_resolution, float2 current_mip_resolution_inv, float2 floor_offset, float2 uv_offset, out float3 position, out float current_t) {
    float2 current_mip_position = current_mip_resolution * origin.xy;

    // Intersect ray with the half box that is pointing away from the ray origin.
    float2 xy_plane = floor(current_mip_position) + floor_offset;
    xy_plane = xy_plane * current_mip_resolution_inv + uv_offset;

    // o + d * t = p' => t = (p' - o) / d
    BNG_PRECISE(float2, t, (xy_plane - origin.xy) * inv_direction.xy);
    current_t = min(t.x, t.y);
    position = origin + current_t * direction;
}

bool FFX_SSSR_AdvanceRay(float3 origin, float3 direction, float3 inv_direction, float2 current_mip_position, float2 current_mip_resolution_inv, float2 floor_offset, float2 uv_offset, float surface_z, inout float3 position, inout float current_t) {
    // Create boundary planes
    float2 xy_plane = floor(current_mip_position) + floor_offset;
    xy_plane = xy_plane * current_mip_resolution_inv + uv_offset;
    float3 boundary_planes = float3(xy_plane, surface_z);

    // Intersect ray with the half box that is pointing away from the ray origin.
    // o + d * t = p' => t = (p' - o) / d
    BNG_PRECISE(float3, t, (boundary_planes - origin) * inv_direction);

    // Prevent using z plane when shooting out of the depth buffer.
#ifdef FFX_SSSR_INVERTED_DEPTH_RANGE
    t.z = direction.z < 0 ? t.z : FFX_SSSR_FLOAT_MAX;
#else
    t.z = direction.z > 0 ? t.z : FFX_SSSR_FLOAT_MAX;
#endif

    // Choose nearest intersection with a boundary.
    float t_min = min(min(t.x, t.y), t.z);

#ifdef FFX_SSSR_INVERTED_DEPTH_RANGE
    // Larger z means closer to the camera.
    bool above_surface = surface_z < position.z;
#else
    // Smaller z means closer to the camera.
    bool above_surface = surface_z > position.z;
#endif

    // Decide whether we are able to advance the ray until we hit the xy boundaries or if we had to clamp it at the surface.
    // We use the asuint comparison to avoid NaN / Inf logic, also we actually care about bitwise equality here to see if t_min is the t.z we fed into the min3 above.
    bool skipped_tile = asuint(t_min) != asuint(t.z) && above_surface;

    // Make sure to only advance the ray if we're still above the surface.
    current_t = above_surface ? t_min : current_t;

    // Advance ray
    position = origin + current_t * direction;

    return skipped_tile;
}

bool FFX_SSSR_IsSkyDepth(float depth) {
#ifdef FFX_SSSR_INVERTED_DEPTH_RANGE
    return depth == 0.0;
#else
    return depth == 1.0;
#endif
}

float FFX_SSSR_DepthSlope(float before, float center, float after, bool before_valid, bool after_valid) {
    before_valid = before_valid && !FFX_SSSR_IsSkyDepth(before);
    after_valid = after_valid && !FFX_SSSR_IsSkyDepth(after);
    float a = center - before;
    float b = after - center;
    if (before_valid && after_valid) {
        // A local extremum can be a one-pixel foreground object. Do not join
        // its two silhouettes into a fictitious sloping surface.
        if (a * b <= 0) return 0;
        if (abs(a - b) <= 0.25 * max(abs(a), abs(b))) return 0.5 * (a + b);
        return abs(a) < abs(b) ? a : b;
    }
    return before_valid ? a : (after_valid ? b : 0.0);
}

float2 FFX_SSSR_LoadDepthSlope(int2 p, float center, float2 screen_size) {
    int2 size = int2(screen_size);
    float left = FFX_SSSR_LoadDepth(max(p - int2(1, 0), 0), 0);
    float right = FFX_SSSR_LoadDepth(min(p + int2(1, 0), size - 1), 0);
    float top = FFX_SSSR_LoadDepth(max(p - int2(0, 1), 0), 0);
    float bottom = FFX_SSSR_LoadDepth(min(p + int2(0, 1), size - 1), 0);
    return float2(FFX_SSSR_DepthSlope(left, center, right, p.x > 0, p.x + 1 < size.x),
                  FFX_SSSR_DepthSlope(top, center, bottom, p.y > 0, p.y + 1 < size.y)) * screen_size;
}

// Intersect a continuous depth plane inside this pixel instead of the flat
// depth step. If it misses the pixel, continue traversal at the next boundary.
bool FFX_SSSR_IntersectPixel(float3 origin, float3 direction, float3 inv_direction, float2 screen_size, float2 floor_offset, float2 uv_offset, float z,
                             inout float3 position, inout float current_t) {
    int2 p = int2(position.xy * screen_size);
    float2 boundary = (float2(p) + floor_offset) / screen_size + uv_offset;
    BNG_PRECISE(float2, exit_t, (boundary - origin.xy) * inv_direction.xy);
    float next_t = min(exit_t.x, exit_t.y);
    bool valid = false;
    float result_t = max(current_t, next_t);
    float3 result_position = origin + result_t * direction;
    if (!FFX_SSSR_IsSkyDepth(z)) {
        float2 slope = FFX_SSSR_LoadDepthSlope(p, z, screen_size);
        float2 center = (float2(p) + 0.5) / screen_size;
        BNG_PRECISE(float, origin_delta, (z - origin.z) + dot(slope, origin.xy - center));
        BNG_PRECISE(float, direction_delta, direction.z - dot(slope, direction.xy));
        // Explicit finite parallel-plane rejection, with one output commit.
        if (abs(direction_delta) >= 1e-20) {
            float plane_t = origin_delta / direction_delta;
            float3 plane_hit = origin + plane_t * direction;
            bool within_footprint = all(abs(plane_hit.xy - position.xy) * screen_size <= 0.01);
#ifdef FFX_SSSR_INVERTED_DEPTH_RANGE
            bool enters_surface = direction_delta < 0;
#else
            bool enters_surface = direction_delta > 0;
#endif
            valid = enters_surface && plane_t >= 0.0 && (plane_t >= current_t || within_footprint) && plane_t <= next_t;
            if (valid) {
                result_t = plane_t;
                result_position = plane_hit;
                result_position.z = z + dot(slope, plane_hit.xy - center);
            }
        }
    }
    current_t = result_t;
    position = result_position;
    return valid;
}

void FFX_SSSR_GetMipResolution(float2 screen_dimensions, float2 inv_screen_dimensions, uint2 max_shift, int mip_level,
                              out float2 resolution, out float2 inv_resolution) {
    // Reduction cells cover exactly 2^mip base pixels. Flooring these UV-grid
    // dimensions stretches coarse cells at resolutions such as 1920x1080.
    // Once an axis reaches one texel, reductions repeat it without extending
    // its footprint over the dropped tail of an odd-sized input.
    uint2 shift = min(uint(mip_level), max_shift);
    // Scaling by powers of two is exact. Hoist the screen-size reciprocals out
    // of traversal instead of dividing twice whenever the ray changes mip.
    resolution = screen_dimensions * asfloat((127u - shift) << 23u);
    inv_resolution = inv_screen_dimensions * float2(uint2(1, 1) << shift);
}

// Requires origin and direction of the ray to be in screen space [0, 1] x [0, 1]
float3 FFX_SSSR_HierarchicalRaymarch(float3 origin, float3 direction, float2 sky_uv, bool is_mirror, float2 screen_size, int most_detailed_mip, uint min_traversal_occupancy, uint max_traversal_intersections, out bool valid_hit, out bool sky_hit, out float current_t) {
    sky_hit = false;
    const bool sky_in_view = all(sky_uv >= 0) && all(sky_uv < 1);
    // The projected ray ends at its direction at infinity. Near the horizon
    // even the first pixel-boundary step can overshoot this endpoint and leave
    // the depth range before an empty sky cell is tested.
    float sky_t = 0;
    if (sky_in_view && any(direction.xy != 0)) {
        sky_t = abs(direction.x) > abs(direction.y)
            ? (sky_uv.x - origin.x) / direction.x
            : (sky_uv.y - origin.y) / direction.y;
        sky_t = max(sky_t, 0.0);
    }
    const float3 inv_direction = beamrtSssrSelect(direction != 0, 1.0 / direction, float3(FFX_SSSR_FLOAT_MAX, FFX_SSSR_FLOAT_MAX, FFX_SSSR_FLOAT_MAX));

    // Start at the requested level, but always refine hits against mip 0.
    const int max_mip = 0; // BeamRT v001 has no owned depth pyramid yet.
    int current_mip = min(most_detailed_mip, max_mip);
    const uint2 max_shift = uint2(firstbithigh(uint2(screen_size)));
    const float2 inv_screen_size = rcp(screen_size);

    // Could recompute these every iteration, but it's faster to hoist them out and update them.
    float2 current_mip_resolution, current_mip_resolution_inv;
    FFX_SSSR_GetMipResolution(screen_size, inv_screen_size, max_shift, current_mip,
                             current_mip_resolution, current_mip_resolution_inv);

    // Step just inside the next cell, measured in base pixels at every mip.
    float2 uv_offset = 0.005 / screen_size;
    uv_offset = beamrtSssrSelect(direction.xy < 0, -uv_offset, uv_offset);

    // Offset applied depending on current mip resolution to move the boundary to the left/right upper/lower border depending on ray direction.
    float2 floor_offset = beamrtSssrSelect(direction.xy < 0, float2(0.0, 0.0), float2(1.0, 1.0));

    // Initially advance ray to avoid immediate self intersections.
    float3 position = origin;
    current_t = 0.0;
    FFX_SSSR_InitialAdvanceRay(origin, direction, inv_direction, current_mip_resolution, current_mip_resolution_inv, floor_offset, uv_offset, position, current_t);

    // Budget depth lookups, not just loop iterations: a fitted mip-0 plane
    // costs five reads. Grazing rays can repeatedly descend to mip 0 without
    // finding a hit, multiplying the old iteration budget by up to five.
    // Mirror rays leave water at grazing angles and cross many horizon cells
    // before reaching the sky. A short budget ends them on the cubemap in blocks.
    uint remaining_lookups = is_mirror ? max_traversal_intersections * 4 : max_traversal_intersections;
    while (remaining_lookups > 0 && current_mip >= 0) {
        bool at_sky = sky_in_view && current_t >= sky_t;
        if (at_sky) {
            current_t = sky_t;
            position = float3(sky_uv, origin.z + sky_t * direction.z);
        }
        if (!(all(position.xy >= 0) && all(position.xy < 1))) break;
        // A finite far plane can precede infinity. Continue checking the
        // remaining sky segment, but retain the depth bounds for other rays.
        if (!sky_in_view && !(position.z > 0 && position.z <= 1)) break;
        // Optional lossy cutoff: sparse-wave retirement makes hit coverage depend
        // on neighboring rays and leaves a grid on smooth receivers. Disabled
        // by default; zero must also bypass the wave vote.
        if (min_traversal_occupancy > 0 && !is_mirror) break; // Unsupported wave cutoff fails closed.
        --remaining_lookups;
        float2 current_mip_position = current_mip_resolution * position.xy;
        // Coarse cells cover powers of two in base pixels. Odd texture sizes
        // leave an uncovered edge strip which must be visited at a finer mip.
        if (any(uint2(current_mip_position) >= max(uint2(screen_size) >> current_mip, 1u))) {
            --current_mip;
            FFX_SSSR_GetMipResolution(screen_size, inv_screen_size, max_shift, current_mip,
                                     current_mip_resolution, current_mip_resolution_inv);
            continue;
        }
        float surface_z = FFX_SSSR_LoadDepth(current_mip_position, current_mip);
        // A nearest-depth mip containing only sky proves this whole cell is
        // empty. If it also contains the ray's direction at infinity, the
        // remaining projected segment stays inside that cell: no object can
        // be skipped. Budget/occupancy exits alone must never imply a sky hit.
        if (sky_in_view && FFX_SSSR_IsSkyDepth(surface_z)
            && all(floor(sky_uv * current_mip_resolution) == floor(current_mip_position))) {
            sky_hit = true;
            break;
        }
        // Reaching infinity is not proof of visibility. Refine occupied cells
        // down to the endpoint pixel; foreground geometry must still hide sky.
        if (at_sky) {
            if (current_mip == 0) break;
            --current_mip;
            FFX_SSSR_GetMipResolution(screen_size, inv_screen_size, max_shift, current_mip,
                                     current_mip_resolution, current_mip_resolution_inv);
            continue;
        }
        bool skipped_tile;
        if (current_mip == 0) {
            if (!FFX_SSSR_IsSkyDepth(surface_z)) {
                if (remaining_lookups < 4) break;
                remaining_lookups -= 4;
            }
            bool hit = FFX_SSSR_IntersectPixel(origin, direction, inv_direction, screen_size, floor_offset, uv_offset, surface_z, position, current_t);
            skipped_tile = !hit;
        } else {
            skipped_tile = FFX_SSSR_AdvanceRay(origin, direction, inv_direction, current_mip_position, current_mip_resolution_inv, floor_offset, uv_offset, surface_z, position, current_t);
        }
        current_mip = min(max_mip, current_mip + (skipped_tile ? 1 : -1));
        // Cell boundaries follow the base-pixel reduction grid, including partial
        // edge cells. Clamp the finished (-1) level, which is never sampled.
        FFX_SSSR_GetMipResolution(screen_size, inv_screen_size, max_shift, max(current_mip, 0),
                                 current_mip_resolution, current_mip_resolution_inv);
    }

    // Only descent past the finest mip denotes a hit. Occupancy, screen exits
    // and the iteration limit must not turn unfinished rays into reflections.
    valid_hit = current_mip < 0;

    return position;
}

float FFX_SSSR_ValidateHit(float3 hit, float2 uv, float3 world_space_ray_direction, float2 screen_size, float depth_buffer_thickness) {
    // Reject hits outside the view frustum
    if (!(all(hit.xy >= 0) && all(hit.xy < 1) && hit.z >= 0 && hit.z <= 1)) {
        return 0;
    }

    // Reject the hit if we didnt advance the ray significantly to avoid immediate self reflection
    float2 manhattan_dist = abs(hit.xy - uv);
    if(all(manhattan_dist < (2 / screen_size))) {
        return 0;
    }

    // Don't lookup radiance from the background.
    int2 texel_coords = int2(screen_size * hit.xy);
    // Validate against the same pixel as the final trace, normal and radiance.
    // A mip-1 minimum belongs to a different surface at silhouettes and rejects
    // otherwise valid distant hits even when the ray landed exactly on mip 0.
    float surface_z = FFX_SSSR_LoadDepth(texel_coords, 0);
#ifdef FFX_SSSR_INVERTED_DEPTH_RANGE
    if (surface_z == 0.0) {
#else
    if (surface_z == 1.0) {
#endif
        return 0;
    }

    // We check if we hit the surface from the back, these should be rejected.
    float3 hit_normal = FFX_SSSR_LoadWorldSpaceNormal(texel_coords);
    if (dot(hit_normal, world_space_ray_direction) > 0) {
        return 0;
    }

    float2 slope = FFX_SSSR_LoadDepthSlope(texel_coords, surface_z, screen_size);
    surface_z += dot(slope, hit.xy - (float2(texel_coords) + 0.5) / screen_size);
    float3 view_space_surface = FFX_SSSR_ScreenSpaceToViewSpace(float3(hit.xy, surface_z));
    float3 view_space_hit = FFX_SSSR_ScreenSpaceToViewSpace(hit);
    float distance = length(view_space_surface - view_space_hit);

    // Fade out hits near the screen borders
    float2 fov = 0.05 * float2(screen_size.y / screen_size.x, 1);
    float2 border = smoothstep(0, fov, hit.xy) * (1 - smoothstep(1 - fov, 1, hit.xy));
    float vignette = border.x * border.y;

    // We accept all hits that are within a reasonable minimum distance below the surface.
    // Add constant in linear space to avoid growing of the reflections toward the reflected objects.
    float confidence = 1 - smoothstep(0, depth_buffer_thickness, distance);
    confidence *= confidence;

    return vignette * confidence;
}

#endif //FFX_SSSR
