#pragma once

#include <cstddef>
#include <optional>
#include <vector>

namespace e2txt {

// 原生窗体元素身份只在类型精确匹配，或有同窗体方法引用与声明类型双重证据时复用。
struct NativeFormElementIdentityEvidence {
	std::size_t index = 0;
	bool resolvedTypeMatches = false;
	bool declaredNativeTypeMatches = false;
	bool ownerMethodReferencesId = false;
};

inline std::optional<std::size_t> SelectUniqueNativeFormElementIdentity(
	const std::vector<NativeFormElementIdentityEvidence>& candidates)
{
	std::optional<std::size_t> exactMatch;
	for (const auto& candidate : candidates) {
		if (!candidate.resolvedTypeMatches) {
			continue;
		}
		if (exactMatch.has_value()) {
			return std::nullopt;
		}
		exactMatch = candidate.index;
	}
	if (exactMatch.has_value()) {
		return exactMatch;
	}

	std::optional<std::size_t> evidencedMatch;
	for (const auto& candidate : candidates) {
		if (!candidate.declaredNativeTypeMatches || !candidate.ownerMethodReferencesId) {
			continue;
		}
		if (evidencedMatch.has_value()) {
			return std::nullopt;
		}
		evidencedMatch = candidate.index;
	}
	return evidencedMatch;
}

} // namespace e2txt
