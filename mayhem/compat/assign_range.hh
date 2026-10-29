// Toolchain shim, force-included (-include) into every C++ compile in mayhem/build.sh.
// The base image ships libstdc++ 14, whose containers lack C++23 assign_range()
// (libstdc++ 15 has it); upstream's src/core/metrics.cc now calls it. Same semantics, no upstream edit.
#pragma once
#include <ranges>
#include <string>
#include <vector>
#if !defined(__cpp_lib_containers_ranges)
#define assign_range(r) assign(std::ranges::begin(r), std::ranges::end(r))
#endif
