#pragma once

#include "e2txt.h"
#include "NativeExpressionReferencePolicy.h"

#include <algorithm>
#include <limits>
#include <optional>
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

// Compare a type in a declaration loaded from an EC with the corresponding
// type preserved in the host project's native dependency table. Imported ECs
// have their own ID space, so an internal user type can legitimately have a
// different ID in the dependency and the host. Such an opaque host ID is
// accepted only when the canonical dependency snapshot names the type at the
// same declaration slot. A host-side name, when present, is authoritative and
// a conflict must not fall through to the dependency-local evidence.
inline bool DoesCanonicalDependencyImportedTypeMatch(
	const std::string& parsedTypeName,
	const std::int32_t parsedResolvedType,
	const std::int32_t hostNativeType,
	const bool hostNativeTypeNameAmbiguous,
	const std::optional<std::string>& hostNativeTypeName,
	const std::int32_t canonicalNativeType,
	const std::optional<std::string>& canonicalNativeTypeName)
{
	if (parsedTypeName.empty()) {
		return hostNativeType == 0;
	}
	if (hostNativeTypeNameAmbiguous) {
		return false;
	}
	if (hostNativeTypeName.has_value()) {
		return *hostNativeTypeName == parsedTypeName;
	}
	if (parsedResolvedType != 0 && parsedResolvedType == hostNativeType) {
		return true;
	}
	if (canonicalNativeType == 0 || !canonicalNativeTypeName.has_value() ||
		*canonicalNativeTypeName != parsedTypeName) {
		return false;
	}

	constexpr std::int32_t kTypeMask = static_cast<std::int32_t>(0xFF000000u);
	constexpr std::int32_t kStaticClassType = 0x09000000;
	constexpr std::int32_t kFormClassType = 0x19000000;
	constexpr std::int32_t kStructType = 0x41000000;
	constexpr std::int32_t kClassType = 0x49000000;
	const auto normalizeUserType = [&](const std::int32_t value) {
		const std::int32_t type = value & kTypeMask;
		if (type == kStaticClassType || type == kFormClassType || type == kClassType) {
			return kClassType;
		}
		return type == kStructType ? kStructType : 0;
	};
	const std::int32_t hostCategory = normalizeUserType(hostNativeType);
	return hostCategory != 0 && hostCategory == normalizeUserType(canonicalNativeType);
}

// Older EC imports can preserve fixed struct-member bounds while omitting the
// redundant array attribute bit in the host table. Treat that single-bit drift
// as equivalent only when identical, non-empty bounds independently prove the
// array declaration; every other attribute and all bounds remain exact.
inline bool DoesNativeDependencyVariableShapeMatch(
	const std::int16_t parsedAttributes,
	const std::int16_t hostAttributes,
	const std::int16_t relevantAttributeMask,
	const std::int16_t arrayAttribute,
	const std::vector<std::int32_t>& parsedBounds,
	const std::vector<std::int32_t>& hostBounds,
	const bool allowBoundEncodedArrayAttribute)
{
	if (parsedBounds != hostBounds) {
		return false;
	}
	const std::int16_t attributeDifference =
		(parsedAttributes ^ hostAttributes) & relevantAttributeMask;
	return attributeDifference == 0 ||
		(allowBoundEncodedArrayAttribute && !parsedBounds.empty() &&
			attributeDifference == arrayAttribute);
}

// A loaded EC has its own native ID space. Select a DLL declaration snapshot
// only when the public text declaration still matches one unique native slot;
// callers can then use its return/parameter type IDs as canonical type-name
// evidence when the host stores an opaque, translated user-type ID.
template <typename Snapshot, typename NormalizeName>
const Snapshot* SelectUniqueCanonicalDependencyDllSnapshot(
	const std::vector<Snapshot>& snapshots,
	const std::string& normalizedName,
	const std::string& declarationDigest,
	const size_t parameterCount,
	NormalizeName&& normalizeName)
{
	const Snapshot* unique = nullptr;
	for (const auto& candidate : snapshots) {
		if (normalizeName(candidate.name) != normalizedName ||
			candidate.textDigest != declarationDigest ||
			candidate.paramTypes.size() != parameterCount) {
			continue;
		}
		if (unique != nullptr) {
			return nullptr;
		}
		unique = &candidate;
	}
	return unique;
}

// Dependency ranges are offsets into the native category table rather than
// numeric-ID intervals.  Restored imported items must therefore keep the exact
// canonical slot order; otherwise a short/reordered import can consume the
// first local item that follows the dependency.
inline bool BuildExactNativeDependencyItemOrder(
	const std::vector<std::int32_t>& emittedIds,
	const std::vector<std::int32_t>& canonicalIds,
	std::vector<size_t>& outOrder)
{
	outOrder.clear();
	if (emittedIds.size() != canonicalIds.size()) {
		return false;
	}
	std::unordered_map<std::int32_t, size_t> emittedIndexById;
	emittedIndexById.reserve(emittedIds.size());
	for (size_t index = 0; index < emittedIds.size(); ++index) {
		if (emittedIds[index] == 0 || !emittedIndexById.emplace(emittedIds[index], index).second) {
			return false;
		}
	}
	outOrder.reserve(canonicalIds.size());
	std::unordered_set<std::int32_t> canonicalIdsSeen;
	canonicalIdsSeen.reserve(canonicalIds.size());
	for (const std::int32_t id : canonicalIds) {
		const auto it = emittedIndexById.find(id);
		if (id == 0 || it == emittedIndexById.end() || !canonicalIdsSeen.insert(id).second) {
			outOrder.clear();
			return false;
		}
		outOrder.push_back(it->second);
	}
	return true;
}

struct NativeDependencyRangeEvidence {
	std::int32_t start = 0;
	std::int32_t count = 0;
	size_t recordIndex = 0;
};

struct NativeDependencyOwnerCandidateEvidence {
	size_t recordIndex = 0;
	bool exactStart = false;
	bool reExport = false;
};

inline std::int32_t SelectNativeDependencyClassType(
	const std::int32_t parsedClassType,
	const std::int32_t trustedNativeClassId)
{
	constexpr std::int32_t kTypeMask = static_cast<std::int32_t>(0xFF000000u);
	constexpr std::int32_t kStaticClassType = 0x09000000;
	constexpr std::int32_t kFormClassType = 0x19000000;
	constexpr std::int32_t kClassType = 0x49000000;
	const std::int32_t nativeType = trustedNativeClassId & kTypeMask;
	if (nativeType == kClassType || nativeType == kStaticClassType || nativeType == kFormClassType) {
		return nativeType;
	}
	return parsedClassType;
}

// A dependency may own methods whose compiler-generated static owner is stored
// in another dependency's class range. Reuse that page only with a complete,
// unique native snapshot and an exact owner ID/category/name relation. The
// caller remains responsible for checking the snapshot's member identities.
inline bool CanReferenceExactNativeStaticClassOwner(
	const std::int32_t classId,
	const std::string& normalizedClassName,
	const std::int32_t methodOwnerClassId,
	const std::string& normalizedMethodOwnerName,
	const bool ownerEvidenceUnique,
	const bool memberEvidenceComplete)
{
	constexpr std::int32_t kTypeMask = static_cast<std::int32_t>(0xFF000000u);
	constexpr std::int32_t kStaticClassType = 0x09000000;
	return ownerEvidenceUnique && memberEvidenceComplete && classId != 0 &&
		(classId & kTypeMask) == kStaticClassType && classId == methodOwnerClassId &&
		!normalizedClassName.empty() &&
		(normalizedMethodOwnerName.empty() || normalizedClassName == normalizedMethodOwnerName);
}

// Overlapping ordered slices can be created by re-exported dependencies. A
// sole candidate owns the symbol. With overlap, an exact range start is the
// strongest evidence; otherwise exactly one direct (non-re-export) record must
// remain or ownership is ambiguous.
inline std::optional<size_t> SelectNativeDependencyOwner(
	const std::vector<NativeDependencyOwnerCandidateEvidence>& rawCandidates)
{
	std::unordered_map<size_t, NativeDependencyOwnerCandidateEvidence> candidatesByRecord;
	for (const auto& candidate : rawCandidates) {
		auto [it, inserted] = candidatesByRecord.emplace(candidate.recordIndex, candidate);
		if (!inserted) {
			it->second.exactStart = it->second.exactStart || candidate.exactStart;
			it->second.reExport = it->second.reExport && candidate.reExport;
		}
	}
	if (candidatesByRecord.size() == 1) {
		return candidatesByRecord.begin()->first;
	}
	std::optional<size_t> exactOwner;
	for (const auto& [recordIndex, candidate] : candidatesByRecord) {
		if (!candidate.exactStart) {
			continue;
		}
		if (exactOwner.has_value()) {
			return std::nullopt;
		}
		exactOwner = recordIndex;
	}
	if (exactOwner.has_value()) {
		return exactOwner;
	}
	std::optional<size_t> directOwner;
	for (const auto& [recordIndex, candidate] : candidatesByRecord) {
		if (candidate.reExport) {
			continue;
		}
		if (directOwner.has_value()) {
			return std::nullopt;
		}
		directOwner = recordIndex;
	}
	return directOwner;
}

inline bool TryBuildNativeDependencyEmissionOrder(
	const std::vector<std::int32_t>& itemIds,
	const std::unordered_map<std::int32_t, size_t>& owners,
	const std::vector<std::vector<std::int32_t>>& orderedRangeIdsByOwner,
	std::vector<std::int32_t>& outIds)
{
	outIds.clear();
	std::unordered_set<std::int32_t> uniqueItemIds;
	for (const std::int32_t id : itemIds) {
		if (id == 0 || !uniqueItemIds.insert(id).second) {
			return false;
		}
	}
	std::unordered_set<std::int32_t> emitted;
	const auto append = [&](const std::int32_t id) {
		if (!uniqueItemIds.contains(id) || !emitted.insert(id).second) {
			return false;
		}
		outIds.push_back(id);
		return true;
	};
	for (const std::int32_t id : itemIds) {
		if (!owners.contains(id) && !append(id)) {
			return false;
		}
	}
	for (size_t ownerIndex = 0; ownerIndex < orderedRangeIdsByOwner.size(); ++ownerIndex) {
		for (const std::int32_t id : orderedRangeIdsByOwner[ownerIndex]) {
			const auto owner = owners.find(id);
			if (owner == owners.end() || owner->second != ownerIndex || emitted.contains(id)) {
				continue;
			}
			if (!append(id)) {
				return false;
			}
		}
	}
	return emitted.size() == itemIds.size();
}

template <typename NormalizeType>
bool ValidateNativeDependencyRanges(
	const std::vector<NativeDependencyRangeEvidence>& ranges,
	NormalizeType&& normalizeType)
{
	struct RangeKey {
		std::int32_t type = 0;
		std::int32_t start = 0;
		size_t recordIndex = 0;
	};
	std::vector<RangeKey> keys;
	keys.reserve(ranges.size());
	for (const auto& range : ranges) {
		if (range.count <= 0) {
			return false;
		}
		const std::int32_t type = normalizeType(range.start);
		const std::int32_t start = range.start & 0x00FFFFFF;
		if (type == 0 || start == 0) {
			return false;
		}
		keys.push_back(RangeKey{ type, start, range.recordIndex });
	}
	std::sort(keys.begin(), keys.end(), [](const RangeKey& left, const RangeKey& right) {
		return std::tie(left.type, left.start, left.recordIndex) <
			std::tie(right.type, right.start, right.recordIndex);
	});
	for (size_t index = 1; index < keys.size(); ++index) {
		if (keys[index - 1].type == keys[index].type &&
			keys[index - 1].start == keys[index].start) {
			return false;
		}
	}
	return true;
}

// EC defined-id start/count pairs address a contiguous slice of the matching
// native program table. Native IDs inside that slice may be sparse or decrease;
// count is never a numeric interval width.
template <typename NormalizeType>
bool TryCollectNativeDependencyOrderedRange(
	const std::int32_t startId,
	const std::int32_t count,
	const std::vector<std::int32_t>& orderedIds,
	NormalizeType&& normalizeType,
	std::vector<std::int32_t>& outIds)
{
	outIds.clear();
	if (count <= 0 || normalizeType(startId) == 0) {
		return false;
	}
	std::vector<std::int32_t> matchingIds;
	matchingIds.reserve(orderedIds.size());
	const std::int32_t rangeType = normalizeType(startId);
	for (const std::int32_t id : orderedIds) {
		if (normalizeType(id) == rangeType) {
			matchingIds.push_back(id);
		}
	}
	const auto startIt = std::find(matchingIds.begin(), matchingIds.end(), startId);
	if (startIt == matchingIds.end()) {
		return false;
	}
	const size_t startIndex = static_cast<size_t>(std::distance(matchingIds.begin(), startIt));
	const size_t itemCount = static_cast<size_t>(count);
	if (matchingIds.empty() || itemCount > matchingIds.size()) {
		return false;
	}
	outIds.reserve(itemCount);
	for (size_t offset = 0; offset < itemCount; ++offset) {
		outIds.push_back(matchingIds[(startIndex + offset) % matchingIds.size()]);
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
void ObserveClaimedNativeEvidenceIds(
	const std::unordered_set<std::int32_t>& claimedIds,
	Observe&& observe)
{
	for (const std::int32_t id : claimedIds) {
		if (id != 0) {
			observe(id);
		}
	}
}

// The program header is the persistent high-water mark, including identities
// removed from the live tables. Seed an allocator from it before allocating a
// new symbol so a deleted identity cannot be reused.
template <typename Observe>
void ObserveNativeProgramHeaderHighWater(
	const std::int32_t versionFlag1,
	Observe&& observe)
{
	if (versionFlag1 > 0) {
		observe(versionFlag1);
	}
}

inline std::int32_t SelectNativeProgramHeaderHighWater(
	const std::int32_t allocatedIdNum,
	const std::optional<std::int32_t> preservedVersionFlag1)
{
	return preservedVersionFlag1.has_value()
		? (std::max)(allocatedIdNum, *preservedVersionFlag1)
		: allocatedIdNum;
}

inline std::unordered_set<std::int32_t> CollectUnemittedNativeEvidenceIds(
	const std::unordered_set<std::int32_t>& candidateIds,
	const std::unordered_set<std::int32_t>& emittedDefinitionIds)
{
	std::unordered_set<std::int32_t> result = candidateIds;
	for (const std::int32_t id : emittedDefinitionIds) {
		result.erase(id);
	}
	return result;
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
