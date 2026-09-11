#pragma once

#include "e2txt.h"
#include "NativeExpressionReferencePolicy.h"

#include <algorithm>
#include <limits>
#include <string>
#include <tuple>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace e2txt {

// Select a host-native dependency symbol only when the public declaration has
// exactly one matching candidate. IDs already owned by local snapshots or a
// previously matched dependency are deliberately ineligible.
template <typename Symbol, typename Matches>
const Symbol* SelectUniqueUnassignedNativeDependencySymbol(
	const std::vector<Symbol>& candidates,
	const std::unordered_set<std::int32_t>& localIds,
	const std::unordered_set<std::int32_t>& claimedIds,
	Matches&& matches)
{
	const Symbol* unique = nullptr;
	for (const auto& candidate : candidates) {
		if (candidate.id == 0 || localIds.contains(candidate.id) || claimedIds.contains(candidate.id)) {
			continue;
		}
		if (!matches(candidate)) {
			continue;
		}
		if (unique != nullptr) {
			return nullptr;
		}
		unique = &candidate;
	}
	return unique;
}

struct NativeDependencyMatchKey {
	std::string name;
	std::string path;
};

// Match editable dependency rows to records parsed from the preserved native
// section without making the result depend on row order. Exact non-empty paths
// win; a name-only fallback is allowed only when at least one path is absent.
inline std::vector<size_t> MatchNativeDependencyRecordsMutuallyUnique(
	const std::vector<NativeDependencyMatchKey>& dependencies,
	const std::vector<NativeDependencyMatchKey>& records)
{
	const size_t missing = (std::numeric_limits<size_t>::max)();
	std::vector<size_t> result(dependencies.size(), missing);
	std::vector<bool> usedRecords(records.size(), false);
	const auto bindPhase = [&](const bool exactPath) {
		std::vector<std::vector<size_t>> candidates(dependencies.size());
		std::vector<size_t> reverseCounts(records.size(), 0);
		for (size_t dependencyIndex = 0; dependencyIndex < dependencies.size(); ++dependencyIndex) {
			if (result[dependencyIndex] != missing) {
				continue;
			}
			const auto& dependency = dependencies[dependencyIndex];
			for (size_t recordIndex = 0; recordIndex < records.size(); ++recordIndex) {
				if (usedRecords[recordIndex]) {
					continue;
				}
				const auto& record = records[recordIndex];
				const bool namesConflict = !dependency.name.empty() && !record.name.empty() &&
					dependency.name != record.name;
				bool matches = false;
				if (exactPath) {
					matches = !dependency.path.empty() && !record.path.empty() &&
						dependency.path == record.path && !namesConflict;
				}
				else {
					matches = (dependency.path.empty() || record.path.empty()) &&
						!dependency.name.empty() && dependency.name == record.name;
				}
				if (matches) {
					candidates[dependencyIndex].push_back(recordIndex);
				}
			}
			for (const size_t recordIndex : candidates[dependencyIndex]) {
				++reverseCounts[recordIndex];
			}
		}
		for (size_t dependencyIndex = 0; dependencyIndex < dependencies.size(); ++dependencyIndex) {
			if (candidates[dependencyIndex].size() != 1) {
				continue;
			}
			const size_t recordIndex = candidates[dependencyIndex].front();
			if (reverseCounts[recordIndex] == 1) {
				result[dependencyIndex] = recordIndex;
				usedRecords[recordIndex] = true;
			}
		}
	};
	bindPhase(true);
	bindPhase(false);
	return result;
}

inline bool IsCompleteNativeDependencyBijection(
	const size_t dependencyCount,
	const size_t recordCount,
	const std::vector<size_t>& matches)
{
	if (dependencyCount != recordCount || matches.size() != dependencyCount) {
		return false;
	}
	std::vector<bool> usedRecords(recordCount, false);
	for (const size_t recordIndex : matches) {
		if (recordIndex >= recordCount || usedRecords[recordIndex]) {
			return false;
		}
		usedRecords[recordIndex] = true;
	}
	return true;
}

struct NativeDependencySourceBindingEvidence {
	std::string editableName;
	std::string editablePath;
	std::string nativeName;
	std::string nativePath;
	std::string loadedPath;
};

inline bool IsCanonicalNativeDependencySourceBinding(
	const NativeDependencySourceBindingEvidence& evidence)
{
	if (!evidence.editableName.empty() && !evidence.nativeName.empty() &&
		evidence.editableName != evidence.nativeName) {
		return false;
	}
	if (!evidence.editablePath.empty() && !evidence.nativePath.empty() &&
		evidence.editablePath != evidence.nativePath) {
		return false;
	}
	if (evidence.loadedPath.empty() ||
		(evidence.editablePath.empty() && evidence.nativePath.empty())) {
		return false;
	}
	return (evidence.editablePath.empty() || evidence.loadedPath == evidence.editablePath) &&
		(evidence.nativePath.empty() || evidence.loadedPath == evidence.nativePath);
}

// A loaded editable module may be combined with host-native dependency evidence
// only when both describe the same canonical source. Workspaces without any
// trusted native record still import their loaded module normally.
inline bool CanImportLoadedDependencyBundle(
	const bool hasTrustedNativeRecord,
	const bool canonicalSourceBindingValid)
{
	return !hasTrustedNativeRecord || canonicalSourceBindingValid;
}

struct NativeDependencyRangeEvidence {
	std::int32_t start = 0;
	std::int32_t count = 0;
	size_t recordIndex = 0;
};

template <typename NormalizeType>
bool ValidateNativeDependencyRanges(
	const std::vector<NativeDependencyRangeEvidence>& ranges,
	NormalizeType&& normalizeType)
{
	struct Span {
		std::int32_t type = 0;
		std::int32_t start = 0;
		std::int32_t end = 0;
		size_t recordIndex = 0;
	};
	std::vector<Span> spans;
	spans.reserve(ranges.size());
	for (const auto& range : ranges) {
		if (range.count <= 0) {
			return false;
		}
		const std::int32_t type = normalizeType(range.start);
		const std::int32_t start = range.start & 0x00FFFFFF;
		const std::int64_t end64 = static_cast<std::int64_t>(start) + range.count - 1;
		if (type == 0 || end64 > 0x00FFFFFF) {
			return false;
		}
		spans.push_back(Span{ type, start, static_cast<std::int32_t>(end64), range.recordIndex });
	}
	std::sort(spans.begin(), spans.end(), [](const Span& left, const Span& right) {
		return std::tie(left.type, left.start, left.end, left.recordIndex) <
			std::tie(right.type, right.start, right.end, right.recordIndex);
	});
	for (size_t index = 1; index < spans.size(); ++index) {
		if (spans[index - 1].type == spans[index].type &&
			spans[index].start <= spans[index - 1].end) {
			return false;
		}
	}
	return true;
}

struct NativePublicDeclarationOccurrence {
	size_t dependencyIndex = 0;
	std::string key;
};

inline bool CanRecoverUnassignedDependencySymbols(
	const bool hasTrustedOriginalBundle,
	const bool allPublicDependenciesParsed,
	const bool hasTrustedNativeDefinedIds,
	const size_t nativeRangeCount)
{
	return hasTrustedOriginalBundle && allPublicDependenciesParsed &&
		hasTrustedNativeDefinedIds && nativeRangeCount != 0;
}

inline bool IsUniquePublicDeclarationForDependency(
	const std::vector<NativePublicDeclarationOccurrence>& occurrences,
	const size_t dependencyIndex,
	const std::string& key)
{
	const NativePublicDeclarationOccurrence* unique = nullptr;
	for (const auto& occurrence : occurrences) {
		if (occurrence.key != key) {
			continue;
		}
		if (unique != nullptr) {
			return false;
		}
		unique = &occurrence;
	}
	return unique != nullptr && unique->dependencyIndex == dependencyIndex;
}

template <typename Observe>
void ObserveNonZeroNativeEvidenceIds(
	const std::vector<std::int32_t>& ids,
	Observe&& observe)
{
	for (const std::int32_t id : ids) {
		if (id != 0) {
			observe(id);
		}
	}
}

inline bool AreNativeEvidenceIdsAvailable(
	const std::vector<std::int32_t>& ids,
	const std::unordered_set<std::int32_t>& localIds,
	const std::unordered_set<std::int32_t>& claimedIds)
{
	std::unordered_set<std::int32_t> uniqueIds;
	for (const std::int32_t id : ids) {
		if (id == 0) {
			continue;
		}
		if (!uniqueIds.insert(id).second || localIds.contains(id) || claimedIds.contains(id)) {
			return false;
		}
	}
	return true;
}

inline void ClaimNativeEvidenceIds(
	const std::vector<std::int32_t>& ids,
	std::unordered_set<std::int32_t>& claimedIds)
{
	for (const std::int32_t id : ids) {
		if (id != 0) {
			claimedIds.insert(id);
		}
	}
}

inline bool IsWellFormedNativeIdOfType(
	const std::int32_t id,
	const std::int32_t expectedType)
{
	constexpr std::int32_t kTypeMask = static_cast<std::int32_t>(0xFF000000u);
	constexpr std::int32_t kNumberMask = 0x00FFFFFF;
	return id != 0 && (id & kTypeMask) == expectedType && (id & kNumberMask) != 0;
}

template <typename Detail>
bool CollectStrictNativeOwnedIds(
	const std::int32_t topLevelId,
	const std::int32_t expectedTopLevelType,
	const std::vector<std::int32_t>& compactChildIds,
	const std::vector<Detail>& detailedChildren,
	const std::int32_t expectedChildType,
	std::vector<std::int32_t>& outOwnedIds,
	std::vector<std::int32_t>& outChildIds)
{
	outOwnedIds.clear();
	outChildIds.clear();
	if (!IsWellFormedNativeIdOfType(topLevelId, expectedTopLevelType) ||
		compactChildIds.size() != detailedChildren.size()) {
		return false;
	}
	std::unordered_set<std::int32_t> uniqueIds;
	uniqueIds.insert(topLevelId);
	std::vector<std::int32_t> childIds;
	childIds.reserve(compactChildIds.size());
	for (size_t index = 0; index < compactChildIds.size(); ++index) {
		const std::int32_t compactId = compactChildIds[index];
		const std::int32_t detailedId = detailedChildren[index].id;
		if (compactId != detailedId ||
			!IsWellFormedNativeIdOfType(compactId, expectedChildType) ||
			!uniqueIds.insert(compactId).second) {
			return false;
		}
		childIds.push_back(compactId);
	}
	outOwnedIds.reserve(1 + childIds.size());
	outOwnedIds.push_back(topLevelId);
	outOwnedIds.insert(outOwnedIds.end(), childIds.begin(), childIds.end());
	outChildIds = std::move(childIds);
	return true;
}

// Coordinates every dependency cursor in one restore. Recovered child IDs are
// reserved before any dependency is emitted, then consumed only by that row.
class NativeChildIdRegistry {
public:
	void ObserveOccupied(const std::int32_t id)
	{
		if (IsWellFormedNativeId(id)) {
			m_occupiedOwners.try_emplace(id, (std::numeric_limits<size_t>::max)());
		}
	}

	bool TryReserveGroup(
		const std::vector<std::int32_t>& ids,
		const std::int32_t expectedType,
		const size_t ownerToken)
	{
		if (ownerToken == 0) {
			return false;
		}
		std::unordered_set<std::int32_t> uniqueIds;
		for (const std::int32_t id : ids) {
			if (!IsWellFormedNativeIdOfType(id, expectedType) ||
				!uniqueIds.insert(id).second || m_occupiedOwners.contains(id) ||
				m_reservedOwners.contains(id)) {
				return false;
			}
		}
		for (const std::int32_t id : ids) {
			m_reservedOwners.emplace(id, ownerToken);
		}
		return true;
	}

	bool TryClaimSequential(
		const std::int32_t id,
		const std::int32_t expectedType,
		const size_t ownerToken)
	{
		if (!IsWellFormedNativeIdOfType(id, expectedType) ||
			ownerToken == 0 || m_occupiedOwners.contains(id) || m_reservedOwners.contains(id)) {
			return false;
		}
		m_occupiedOwners.emplace(id, ownerToken);
		return true;
	}

	bool TryClaimPreferred(
		const std::int32_t id,
		const std::int32_t expectedType,
		const size_t ownerToken)
	{
		if (!IsWellFormedNativeIdOfType(id, expectedType) ||
			ownerToken == 0 || m_occupiedOwners.contains(id)) {
			return false;
		}
		if (const auto it = m_reservedOwners.find(id); it != m_reservedOwners.end()) {
			if (ownerToken == 0 || it->second != ownerToken) {
				return false;
			}
			m_reservedOwners.erase(it);
		}
		m_occupiedOwners.emplace(id, ownerToken);
		return true;
	}

	bool IsOccupiedOrReserved(const std::int32_t id) const
	{
		return m_occupiedOwners.contains(id) || m_reservedOwners.contains(id);
	}

private:
	static bool IsWellFormedNativeId(const std::int32_t id)
	{
		constexpr std::int32_t kTypeMask = static_cast<std::int32_t>(0xFF000000u);
		constexpr std::int32_t kNumberMask = 0x00FFFFFF;
		return id != 0 && (id & kTypeMask) != 0 && (id & kNumberMask) != 0;
	}

	std::unordered_map<std::int32_t, size_t> m_occupiedOwners;
	std::unordered_map<std::int32_t, size_t> m_reservedOwners;
};

enum class NativeUnassignedSymbolKind {
	Class,
	Struct,
	Method,
	Constant,
};

inline bool CanCollectUnassignedNativeDependencySymbol(
	const NativeUnassignedSymbolKind kind)
{
	return kind != NativeUnassignedSymbolKind::Constant;
}

struct NativeDependencyVariableShape {
	std::string typeName;
	std::int16_t attr = 0;
	std::vector<std::int32_t> arrayBounds;
	bool operator==(const NativeDependencyVariableShape&) const = default;
};

struct NativeDependencyMethodShape {
	std::string returnTypeName;
	std::vector<NativeDependencyVariableShape> params;
	bool operator==(const NativeDependencyMethodShape&) const = default;
};
} // namespace e2txt
