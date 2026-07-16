#include <metal_stdlib>
using namespace metal;

// Sentinel kernel used only by Task 1's "library loads" test. Real kernels
// are added in later tasks; this file grows into the full MSL source.
kernel void noop_kernel(device uint* out [[buffer(0)]], uint gid [[thread_position_in_grid]]) {
    if (gid == 0) { out[0] = 0x4d657461; }  // "Meta"
}
