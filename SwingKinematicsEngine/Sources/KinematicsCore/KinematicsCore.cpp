// KinematicsCore.cpp
#include "KinematicsCore.hpp"

#include <cmath>

namespace skc {

Vec3 principalDirection3(const double* xyz, std::size_t count) {
    if (xyz == nullptr || count < 2) {
        return Vec3{0.0, 0.0, 0.0};
    }

    // Mean-center.
    double mx = 0.0, my = 0.0, mz = 0.0;
    for (std::size_t i = 0; i < count; ++i) {
        mx += xyz[3 * i + 0];
        my += xyz[3 * i + 1];
        mz += xyz[3 * i + 2];
    }
    const double n = static_cast<double>(count);
    mx /= n; my /= n; mz /= n;

    // Symmetric covariance matrix (only the 6 unique entries).
    double cxx = 0.0, cxy = 0.0, cxz = 0.0, cyy = 0.0, cyz = 0.0, czz = 0.0;
    for (std::size_t i = 0; i < count; ++i) {
        const double dx = xyz[3 * i + 0] - mx;
        const double dy = xyz[3 * i + 1] - my;
        const double dz = xyz[3 * i + 2] - mz;
        cxx += dx * dx; cxy += dx * dy; cxz += dx * dz;
        cyy += dy * dy; cyz += dy * dz; czz += dz * dz;
    }

    // Power iteration for the dominant eigenvector of the 3x3 symmetric matrix.
    // Seed with the raw end-to-end displacement so we converge fast and inherit
    // a meaningful sign even on near-collinear data.
    double vx = xyz[3 * (count - 1) + 0] - xyz[0];
    double vy = xyz[3 * (count - 1) + 1] - xyz[1];
    double vz = xyz[3 * (count - 1) + 2] - xyz[2];
    double seedNorm = std::sqrt(vx * vx + vy * vy + vz * vz);
    if (seedNorm <= 1e-12) { vx = 1.0; vy = 0.0; vz = 0.0; }

    for (int iter = 0; iter < 64; ++iter) {
        const double nx = cxx * vx + cxy * vy + cxz * vz;
        const double ny = cxy * vx + cyy * vy + cyz * vz;
        const double nz = cxz * vx + cyz * vy + czz * vz;
        const double norm = std::sqrt(nx * nx + ny * ny + nz * nz);
        if (norm <= 1e-12) {
            break; // Covariance annihilates the iterate: no spread along any axis.
        }
        const double ux = nx / norm, uy = ny / norm, uz = nz / norm;
        const double delta = std::fabs(ux - vx) + std::fabs(uy - vy) + std::fabs(uz - vz);
        vx = ux; vy = uy; vz = uz;
        if (delta < 1e-10) {
            break;
        }
    }

    // Disambiguate sign: the axis should point from the first sample to the last.
    const double dirx = xyz[3 * (count - 1) + 0] - xyz[0];
    const double diry = xyz[3 * (count - 1) + 1] - xyz[1];
    const double dirz = xyz[3 * (count - 1) + 2] - xyz[2];
    if (vx * dirx + vy * diry + vz * dirz < 0.0) {
        vx = -vx; vy = -vy; vz = -vz;
    }

    return Vec3{vx, vy, vz};
}

} // namespace skc
