#pragma once

#include <cstdint>
#include <cstring>
#include <unordered_set>
#include <vector>

namespace e2txt {

namespace native_reference_policy_detail {

inline bool TryReadNativeI16(
	const std::vector<std::uint8_t>& data,
	size_t& position,
	std::int16_t& outValue)
{
	if (position + sizeof(outValue) > data.size()) {
		return false;
	}
	std::memcpy(&outValue, data.data() + position, sizeof(outValue));
	position += sizeof(outValue);
	return true;
}

inline bool TryReadNativeI32(
	const std::vector<std::uint8_t>& data,
	size_t& position,
	std::int32_t& outValue)
{
	if (position + sizeof(outValue) > data.size()) {
		return false;
	}
	std::memcpy(&outValue, data.data() + position, sizeof(outValue));
	position += sizeof(outValue);
	return true;
}

inline bool TrySkipNativeBytes(
	const std::vector<std::uint8_t>& data,
	size_t& position,
	const size_t count)
{
	if (position + count > data.size()) {
		return false;
	}
	position += count;
	return true;
}

inline bool TrySkipNativeBStr(
	const std::vector<std::uint8_t>& data,
	size_t& position)
{
	std::int32_t size = 0;
	return TryReadNativeI32(data, position, size) &&
		size >= 0 &&
		TrySkipNativeBytes(data, position, static_cast<size_t>(size));
}

inline void InspectNativeEvidenceId(
	const std::int32_t value,
	const std::unordered_set<std::int32_t>& unstableIds,
	bool& outFound)
{
	if (unstableIds.contains(value)) {
		outFound = true;
	}
}

inline bool TryInspectNativeExpressionEvidence(
	const std::vector<std::uint8_t>& data,
	size_t& position,
	const std::unordered_set<std::int32_t>& unstableIds,
	bool& outFound,
	bool parseMember = true);

inline bool TryInspectNativeParamListEvidence(
	const std::vector<std::uint8_t>& data,
	size_t& position,
	const std::unordered_set<std::int32_t>& unstableIds,
	bool& outFound)
{
	while (position < data.size()) {
		if (data[position] == 0x01) {
			++position;
			return true;
		}
		if (!TryInspectNativeExpressionEvidence(data, position, unstableIds, outFound)) {
			return false;
		}
	}
	return false;
}

inline bool TryInspectNativeCallEvidence(
	const std::vector<std::uint8_t>& data,
	size_t& position,
	const std::unordered_set<std::int32_t>& unstableIds,
	bool& outFound)
{
	std::int32_t methodId = 0;
	std::int16_t libraryId = 0;
	std::int16_t flags = 0;
	if (!TryReadNativeI32(data, position, methodId) ||
		!TryReadNativeI16(data, position, libraryId) ||
		!TryReadNativeI16(data, position, flags) ||
		!TrySkipNativeBStr(data, position) ||
		!TrySkipNativeBStr(data, position)) {
		return false;
	}
	(void)libraryId;
	(void)flags;
	InspectNativeEvidenceId(methodId, unstableIds, outFound);
	if (position == data.size()) {
		return true;
	}

	const std::uint8_t marker = data[position];
	if (marker == 0x38) {
		if (!TryInspectNativeExpressionEvidence(data, position, unstableIds, outFound)) {
			return false;
		}
	}
	else if (marker == 0x36) {
		++position;
	}
	else {
		return false;
	}
	return TryInspectNativeParamListEvidence(data, position, unstableIds, outFound);
}

inline bool TryInspectNativeExpressionEvidence(
	const std::vector<std::uint8_t>& data,
	size_t& position,
	const std::unordered_set<std::int32_t>& unstableIds,
	bool& outFound,
	const bool parseMember)
{
	while (position < data.size() && (data[position] == 0x1D || data[position] == 0x37)) {
		++position;
	}
	if (position >= data.size()) {
		return false;
	}

	const std::uint8_t type = data[position++];
	switch (type) {
	case 0x16:
		break;
	case 0x17:
	case 0x19:
		return TrySkipNativeBytes(data, position, sizeof(double));
	case 0x18:
		return TrySkipNativeBytes(data, position, sizeof(std::int16_t));
	case 0x1A:
		return TrySkipNativeBStr(data, position);
	case 0x1B:
	case 0x1E: {
		std::int32_t id = 0;
		if (!TryReadNativeI32(data, position, id)) {
			return false;
		}
		InspectNativeEvidenceId(id, unstableIds, outFound);
		break;
	}
	case 0x1C:
		return TrySkipNativeBytes(data, position, sizeof(std::int16_t) * 2);
	case 0x1F:
		while (position < data.size() && data[position] != 0x20) {
			if (!TryInspectNativeExpressionEvidence(data, position, unstableIds, outFound)) {
				return false;
			}
		}
		if (position >= data.size()) {
			return false;
		}
		++position;
		break;
	case 0x21:
		if (!TryInspectNativeCallEvidence(data, position, unstableIds, outFound)) {
			return false;
		}
		break;
	case 0x23:
		return TrySkipNativeBytes(
			data,
			position,
			sizeof(std::int16_t) * 2 + sizeof(std::int32_t));
	case 0x38: {
		std::int32_t variableId = 0;
		if (!TryReadNativeI32(data, position, variableId)) {
			return false;
		}
		InspectNativeEvidenceId(variableId, unstableIds, outFound);
		if (variableId == 0x0500FFFE) {
			if (position >= data.size() || data[position++] != 0x3A) {
				return false;
			}
			return TryInspectNativeExpressionEvidence(data, position, unstableIds, outFound);
		}
		break;
	}
	case 0x3B:
		return TrySkipNativeBytes(data, position, sizeof(std::int32_t));
	case 0x6A:
	case 0x6B:
	case 0x6C:
	case 0x6E:
	case 0x70:
	case 0x71:
		return TryInspectNativeCallEvidence(data, position, unstableIds, outFound);
	default:
		return false;
	}

	const bool allowMemberChain = type == 0x38 || type == 0x21;
	if (!allowMemberChain || !parseMember) {
		return true;
	}
	while (position < data.size()) {
		if (data[position] == 0x39) {
			++position;
			std::int32_t memberId = 0;
			std::int32_t ownerTypeId = 0;
			if (!TryReadNativeI32(data, position, memberId) ||
				!TryReadNativeI32(data, position, ownerTypeId)) {
				return false;
			}
			InspectNativeEvidenceId(memberId, unstableIds, outFound);
			InspectNativeEvidenceId(ownerTypeId, unstableIds, outFound);
			continue;
		}
		if (data[position] == 0x3A) {
			++position;
			if (!TryInspectNativeExpressionEvidence(data, position, unstableIds, outFound, false)) {
				return false;
			}
			continue;
		}
		if (data[position] == 0x37) {
			++position;
			continue;
		}
		break;
	}
	return true;
}

inline bool TryInspectNativeReferenceSlot(
	const std::vector<std::uint8_t>& expressionData,
	const std::int32_t reference,
	const std::unordered_set<std::int32_t>& unstableIds,
	bool& outFound)
{
	if (reference < 0 || static_cast<size_t>(reference) >= expressionData.size()) {
		return false;
	}
	size_t position = static_cast<size_t>(reference);
	return TryInspectNativeExpressionEvidence(expressionData, position, unstableIds, outFound);
}

}  // namespace native_reference_policy_detail

// Native reference tables identify the only expression offsets that may carry
// relocatable method, variable/member, or constant IDs. Parse from those slots
// so an identical four-byte sequence inside text or numeric payload cannot
// invalidate an otherwise reusable native line.
inline bool NativeExpressionReferenceSlotsContainAnyEvidenceId(
	const std::vector<std::uint8_t>& expressionData,
	const std::vector<std::int32_t>& methodReferences,
	const std::vector<std::int32_t>& variableReferences,
	const std::vector<std::int32_t>& constantReferences,
	const std::unordered_set<std::int32_t>& unstableIds)
{
	if (expressionData.empty() || unstableIds.empty()) {
		return false;
	}

	std::unordered_set<std::int32_t> inspectedReferences;
	for (const auto* references : { &methodReferences, &variableReferences, &constantReferences }) {
		for (const std::int32_t reference : *references) {
			if (!inspectedReferences.insert(reference).second) {
				continue;
			}
			bool found = false;
			if (!native_reference_policy_detail::TryInspectNativeReferenceSlot(
					expressionData,
					reference,
					unstableIds,
					found)) {
				// A malformed proven reference cannot be safely copied when an ID
				// migration is active, even though no byte-window guess is made.
				return true;
			}
			if (found) {
				return true;
			}
		}
	}
	return false;
}

}  // namespace e2txt
