#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <vector>

namespace e2txt {

inline bool DoesSupplementalNativeMethodTextIdentityMatch(
	const std::string_view nativeTextDigest,
	const std::string_view currentTextDigest,
	const std::string_view currentTextDigestWithNativePublicity,
	const bool nativePublicityMatchesCurrentText)
{
	if (nativeTextDigest.empty()) {
		return false;
	}
	const std::string_view expectedDigest = nativePublicityMatchesCurrentText
		? currentTextDigest
		: currentTextDigestWithNativePublicity;
	return !expectedDigest.empty() && nativeTextDigest == expectedDigest;
}

inline std::int32_t ApplyParsedMethodPublicityToNativeAttr(
	const std::int32_t nativeAttr,
	const bool isPublic)
{
	return isPublic ? (nativeAttr | 0x8) : (nativeAttr & ~0x8);
}

// 补充原生方法身份必须由同一宿主、完整声明摘要和有效的非零原生地址共同证明。
struct SupplementalNativeMethodIdentityEvidence {
	std::size_t index = 0;
	bool ownerIdentityMatches = false;
	bool methodNameMatches = false;
	bool declarationShapeMatches = false;
	bool methodTextIdentityMatchesAfterNativePublicity = false;
	bool methodIdIsValid = false;
	bool memoryAddressIsValid = false;
};

inline std::optional<std::size_t> SelectUniqueSupplementalNativeMethodIdentity(
	const std::vector<SupplementalNativeMethodIdentityEvidence>& candidates,
	const bool trustedMethodAlreadyExists)
{
	if (trustedMethodAlreadyExists) {
		return std::nullopt;
	}
	std::optional<std::size_t> match;
	for (const auto& candidate : candidates) {
		if (!candidate.ownerIdentityMatches ||
			!candidate.methodNameMatches ||
			!candidate.declarationShapeMatches ||
			!candidate.methodTextIdentityMatchesAfterNativePublicity ||
			!candidate.methodIdIsValid ||
			!candidate.memoryAddressIsValid) {
			continue;
		}
		if (match.has_value()) {
			return std::nullopt;
		}
		match = candidate.index;
	}
	return match;
}

} // namespace e2txt
