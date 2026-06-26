// KinematicsCore.hpp
//
// Header-declared C++ core for the heavy linear-algebra primitives used by the
// SwingKinematicsEngine. These are deliberately dependency-free (only <cstddef>)
// so the module compiles cleanly under Swift/C++ interoperability on every
// Apple platform without pulling Accelerate into the C++ translation unit.
//
// The Swift layer (SIMD/Accelerate) owns orchestration, unit handling, and the
// 1-D velocity regressions (vDSP). This core owns the one primitive Accelerate
// does not provide directly:
//   * principalDirection3 -> 3-D best-fit line direction via covariance PCA
//
#pragma once

#include <cstddef>

namespace skc {

/// A plain 3-component double vector. Trivially bridged to Swift's SIMD3<Double>.
struct Vec3 {
    double x;
    double y;
    double z;
};

/// Dominant principal axis (unit vector) of an Nx3 point cloud.
///
/// Computes the mean-centered 3x3 covariance matrix and extracts its largest
/// eigenvector via symmetric power iteration. This yields the best-fit line
/// direction through the points — used to recover the club-head travel
/// direction (club path) from a window of back-projected world positions.
///
/// `xyz` must point to `count * 3` doubles laid out [x0,y0,z0, x1,y1,z1, ...].
/// The returned vector is normalized; the sign is disambiguated to point from
/// the first sample toward the last. Returns {0,0,0} when count < 2.
Vec3 principalDirection3(const double* xyz, std::size_t count);

} // namespace skc
