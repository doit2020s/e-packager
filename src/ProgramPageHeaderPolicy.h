#pragma once

#include <cstddef>
#include <string_view>

namespace e2txt {

inline constexpr std::string_view kExplicitRootObjectClassName = "<对象>";

inline bool IsUserClassProgramHeader(
	const std::size_t fieldCount,
	const std::string_view normalizedBaseClassName)
{
	// A single trailing comma is the legacy, explicit no-parent class marker.
	// Empty base slots needed to reach publicity/comment fields belong to an
	// ordinary assembly; user classes with those fields use <对象> explicitly.
	return !normalizedBaseClassName.empty() ||
		(fieldCount == 2 && normalizedBaseClassName.empty());
}

} // namespace e2txt
