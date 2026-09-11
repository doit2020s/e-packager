#include "../src/RoundtripEvidencePolicy.h"
#include "../src/NativeDependencyEvidencePolicy.h"
#include "../src/NativeFormIdentityPolicy.h"
#include "../src/NativeMethodIdentityPolicy.h"
#include <iostream>

int main()
{
	int failures = 0;
	const auto check = [&failures](bool condition, const char* label) {
		if (!condition) { std::cerr << label << '\n'; ++failures; }
	};
	using nlohmann::json;
	json first = {{"sourceMd5", "first"}, {"sourceSize", 10}, {"sourceFileKind", "e"}, {"version", 1}};
	json second = {{"sourceMd5", "second"}, {"sourceSize", 20}, {"sourceFileKind", "e"}, {"version", 1}};
	e2txt::NormalizeRoundtripSourceInfo(first, "info.json");
	e2txt::NormalizeRoundtripSourceInfo(second, "info.json");
	check(first == second, "file provenance must not require byte-identical serialization");
	second["sourceFileKind"] = "ec";
	check(first != second, "source kind must remain significant");
	json resource = {{"sourceMd5", "resource-hash"}, {"sourceSize", 10}};
	const json originalResource = resource;
	e2txt::NormalizeRoundtripSourceInfo(resource, "image/info.json");
	check(resource == originalResource, "nested resource metadata must remain exact");
	for (const char* path : {"project/.native_source.bin", "project/.native_source_map.json", "project/.native_symbol_map.json"})
		check(e2txt::IsRoundtripEvidenceFile(path), "known reconstruction evidence must be excluded from byte equality");
	for (const char* path : {"project/_meta.json", "project/.module.json", "project/.native_unknown.bin", "src/main.txt", "image/data.bin", "audio/data.bin"})
		check(!e2txt::IsRoundtripEvidenceFile(path), "project content must still be compared");

	const std::unordered_set<std::int32_t> noIds;
	std::vector<e2txt::NativeDependencyClassSymbol> classes = {
		{0x4908A4CE, 0, 0, -1, "ImportedClass"},
	};
	const auto classMatches = [](const e2txt::NativeDependencyClassSymbol& item) {
		return item.name == "ImportedClass";
	};
	const auto* importedClass = e2txt::SelectUniqueUnassignedNativeDependencySymbol(
		classes, noIds, noIds, classMatches);
	check(importedClass != nullptr && importedClass->id == 0x4908A4CE,
		"unique imported class evidence must retain its host-native id");
	classes.push_back({0x4908A4CF, 0, 0, -1, "ImportedClass"});
	check(e2txt::SelectUniqueUnassignedNativeDependencySymbol(
		classes, noIds, noIds, classMatches) == nullptr,
		"duplicate imported owner names must not authorize either id");
	classes.resize(1);
	const std::unordered_set<std::int32_t> occupiedClassIds = {0x4908A4CE};
	check(e2txt::SelectUniqueUnassignedNativeDependencySymbol(
		classes, occupiedClassIds, noIds, classMatches) == nullptr,
		"an imported owner id occupied by a local snapshot must not be authorized");
	classes.push_back({0x4908A4CF, 0, 0, -1, "ImportedClass"});
	const auto* remainingEligibleClass = e2txt::SelectUniqueUnassignedNativeDependencySymbol(
		classes, occupiedClassIds, noIds, classMatches);
	check(remainingEligibleClass != nullptr && remainingEligibleClass->id == 0x4908A4CF,
		"excluded local candidates must be filtered before uniqueness is decided");
	classes.resize(1);

	std::vector<e2txt::NativeDependencyMethodSymbol> methods(1);
	methods[0].id = 0x04092D87;
	methods[0].ownerClassId = 0x4908A4CE;
	methods[0].ownerClassName = "ImportedClass";
	methods[0].name = "Initialize";
	const auto methodMatches = [](const e2txt::NativeDependencyMethodSymbol& item) {
		return item.ownerClassName == "ImportedClass" && item.name == "Initialize";
	};
	const auto* importedMethod = e2txt::SelectUniqueUnassignedNativeDependencySymbol(
		methods, noIds, noIds, methodMatches);
	check(importedMethod != nullptr && importedMethod->ownerClassId == 0x4908A4CE,
		"unique owner-qualified method evidence must retain its host-native id");
	methods.push_back(methods[0]);
	methods.back().id = 0x04092D88;
	check(e2txt::SelectUniqueUnassignedNativeDependencySymbol(
		methods, noIds, noIds, methodMatches) == nullptr,
		"duplicate owner-qualified method names must not authorize either id");
	methods.resize(1);
	const std::unordered_set<std::int32_t> trustedLocalMethodIds = {0x04092D87};
	check(e2txt::SelectUniqueUnassignedNativeDependencySymbol(
		methods, trustedLocalMethodIds, noIds, methodMatches) == nullptr,
		"a method id occupied by the trusted original native bundle must not be recovered");

	std::vector<e2txt::NativeDependencyStructSymbol> structs(1);
	structs[0].id = 0x41092C43;
	structs[0].name = "WindowOptions";
	structs[0].members.push_back({0x42092C44, -2147483644, 0, "Title", {}});
	const auto structMatches = [](const e2txt::NativeDependencyStructSymbol& item) {
		return item.name == "WindowOptions" && item.members.size() == 1 &&
			item.members[0].name == "Title" && item.members[0].dataType == -2147483644;
	};
	const auto* importedStruct = e2txt::SelectUniqueUnassignedNativeDependencySymbol(
		structs, noIds, noIds, structMatches);
	check(importedStruct != nullptr && importedStruct->id == 0x41092C43,
		"a unique public struct declaration must retain its host-native type id");
	const std::unordered_set<std::int32_t> occupiedStructIds = {0x41092C43};
	check(e2txt::SelectUniqueUnassignedNativeDependencySymbol(
		structs, occupiedStructIds, noIds, structMatches) == nullptr,
		"a struct id occupied by the trusted original bundle must not be recovered");
	structs[0].members[0].dataType = -2147482879;
	check(e2txt::SelectUniqueUnassignedNativeDependencySymbol(
		structs, noIds, noIds, structMatches) == nullptr,
		"a public struct member signature mismatch must fail closed");
	structs[0].members[0].dataType = -2147483644;
	structs.push_back(structs[0]);
	structs.back().id = 0x41092C45;
	structs.back().members[0].id = 0x42092C46;
	check(e2txt::SelectUniqueUnassignedNativeDependencySymbol(
		structs, noIds, noIds, structMatches) == nullptr,
		"duplicate native struct candidates with the same full declaration must fail closed");
	check(!e2txt::AreNativeEvidenceIdsAvailable(
		std::vector<std::int32_t>{0x04092D87, 0x25092D88},
		std::unordered_set<std::int32_t>{0x25092D88},
		noIds),
		"a recovered method parameter id occupied by a trusted local snapshot must fail closed");
	check(!e2txt::AreNativeEvidenceIdsAvailable(
		std::vector<std::int32_t>{0x25092D88, 0x25092D88}, noIds, noIds),
		"duplicate child ids inside one native declaration must fail closed");

	const size_t missing = (std::numeric_limits<size_t>::max)();
	const std::vector<e2txt::NativeDependencyMatchKey> dependencyKeys = {
		{"shared", "c:\\mods\\first.ec"},
		{"shared", "c:\\mods\\second.ec"},
		{"legacy", ""},
	};
	const std::vector<e2txt::NativeDependencyMatchKey> recordKeys = {
		{"shared", "c:\\mods\\second.ec"},
		{"legacy", "c:\\mods\\legacy.ec"},
		{"shared", "c:\\mods\\first.ec"},
	};
	const auto dependencyMatches = e2txt::MatchNativeDependencyRecordsMutuallyUnique(
		dependencyKeys, recordKeys);
	check(dependencyMatches.size() == 3 &&
		dependencyMatches[0] == 2 && dependencyMatches[1] == 0 && dependencyMatches[2] == 1,
		"exact paths must disambiguate same-named dependency records before a unique name fallback");
	const auto mismatchedPaths = e2txt::MatchNativeDependencyRecordsMutuallyUnique(
		std::vector<e2txt::NativeDependencyMatchKey>{{"shared", "c:\\mods\\a.ec"}},
		std::vector<e2txt::NativeDependencyMatchKey>{{"shared", "c:\\mods\\b.ec"}});
	check(mismatchedPaths.size() == 1 && mismatchedPaths[0] == missing,
		"a shared name must not override two conflicting non-empty paths");
	const auto duplicatePaths = e2txt::MatchNativeDependencyRecordsMutuallyUnique(
		std::vector<e2txt::NativeDependencyMatchKey>{{"shared", "c:\\mods\\same.ec"}},
		std::vector<e2txt::NativeDependencyMatchKey>{
			{"shared", "c:\\mods\\same.ec"},
			{"shared", "c:\\mods\\same.ec"},
		});
	check(duplicatePaths.size() == 1 && duplicatePaths[0] == missing,
		"duplicate native records with the same exact path must fail closed");
	const auto reverseAmbiguity = e2txt::MatchNativeDependencyRecordsMutuallyUnique(
		std::vector<e2txt::NativeDependencyMatchKey>{
			{"", "c:\\mods\\same.ec"},
			{"shared", "c:\\mods\\same.ec"},
		},
		std::vector<e2txt::NativeDependencyMatchKey>{
			{"shared", "c:\\mods\\same.ec"},
			{"", "c:\\mods\\same.ec"},
		});
	check(reverseAmbiguity.size() == 2 &&
		reverseAmbiguity[0] == missing && reverseAmbiguity[1] == missing,
		"a record claimed by another path-compatible dependency must fail the reverse-unique check");
	check(e2txt::IsCompleteNativeDependencyBijection(3, 3, dependencyMatches),
		"a one-to-one dependency/native record match must form a complete bijection");
	check(!e2txt::IsCompleteNativeDependencyBijection(3, 4, dependencyMatches) &&
		!e2txt::IsCompleteNativeDependencyBijection(3, 3, {2, 0, 0}) &&
		!e2txt::IsCompleteNativeDependencyBijection(3, 3, {2, 0}),
		"unmatched, duplicate, or count-mismatched native records must disable recovery");
	check(e2txt::IsCanonicalNativeDependencySourceBinding({
		"shared", "c:\\mods\\first.ec", "shared", "c:\\mods\\first.ec", "c:\\mods\\first.ec"}),
		"editable, native, and loaded EC identities may authorize only the same canonical source");
	check(!e2txt::IsCanonicalNativeDependencySourceBinding({
		"shared", "c:\\mods\\first.ec", "shared", "c:\\mods\\first.ec", "c:\\redirect\\first.ec"}) &&
		!e2txt::IsCanonicalNativeDependencySourceBinding({
		"shared", "c:\\mods\\first.ec", "other", "c:\\mods\\first.ec", "c:\\mods\\first.ec"}) &&
		!e2txt::IsCanonicalNativeDependencySourceBinding({
		"shared", "", "shared", "", "c:\\mods\\first.ec"}),
		"redirected, name-conflicting, or source-less dependency loads must fail closed");
	check(e2txt::CanImportLoadedDependencyBundle(true, true) &&
		e2txt::CanImportLoadedDependencyBundle(false, false),
		"a loaded module may be imported with matching native evidence or without any trusted native record");
	check(!e2txt::CanImportLoadedDependencyBundle(true, false),
		"a redirected fallback module must never be mixed with another source's trusted native evidence");
	check(e2txt::DoesCanonicalDependencyImportedTypeMatch(
		"AnonymousType141",
		0x41012F83,
		0x4101EE40,
		false,
		std::nullopt,
		0x41012F83,
		std::optional<std::string>("AnonymousType141")),
		"a canonical dependency snapshot may bind an opaque host-side user type in the same declaration slot");
	check(!e2txt::DoesCanonicalDependencyImportedTypeMatch(
		"AnonymousType141",
		0x4101EE40,
		0x4101EE40,
		false,
		std::optional<std::string>("DifferentHostType"),
		0x41012F83,
		std::optional<std::string>("AnonymousType141")),
		"a conflicting host-side type name must reject even an exact resolved id");
	check(!e2txt::DoesCanonicalDependencyImportedTypeMatch(
		"AnonymousType141",
		0x41012F83,
		0x4101EE40,
		true,
		std::nullopt,
		0x41012F83,
		std::optional<std::string>("AnonymousType141")),
		"an ambiguous host-side type identity must not fall through to canonical dependency evidence");
	check(!e2txt::DoesCanonicalDependencyImportedTypeMatch(
		"AnonymousType141",
		0x41012F83,
		0x4101EE40,
		false,
		std::nullopt,
		0,
		std::nullopt) &&
		!e2txt::DoesCanonicalDependencyImportedTypeMatch(
			"AnonymousType141",
			0x41012F83,
			0x4101EE40,
			false,
			std::nullopt,
			0x41012F83,
			std::optional<std::string>("ChangedMemberType")),
		"missing or changed canonical member-type evidence must fail closed");
	check(!e2txt::DoesCanonicalDependencyImportedTypeMatch(
		"AnonymousType141",
		0x41012F83,
		0x4901EE40,
		false,
		std::nullopt,
		0x41012F83,
		std::optional<std::string>("AnonymousType141")),
		"opaque host and canonical dependency types must remain in the same user-type category");
	const std::unordered_set<std::int32_t> unstableMemberIds = {0x42092C44};
	const std::vector<std::uint8_t> realVariableReference = {
		0x1D, 0x38, 0x44, 0x2C, 0x09, 0x42, 0x37,
	};
	check(e2txt::NativeExpressionReferenceSlotsContainAnyEvidenceId(
		realVariableReference,
		{},
		{0},
		{},
		unstableMemberIds),
		"a proven variable-reference slot containing a remapped id must be rebuilt");
	const std::vector<std::uint8_t> unexaminedCallWithSameBytes = {
		0x6A,
		0x00, 0x00, 0x00, 0x00,
		0xFF, 0xFF,
		0x40, 0x00,
		0x06, 0x00, 0x00, 0x00,
		0x7E, 0x44, 0x2C, 0x09, 0x42, 0x00,
		0x00, 0x00, 0x00, 0x00,
		0x36, 0x01,
	};
	check(!e2txt::NativeExpressionReferenceSlotsContainAnyEvidenceId(
		unexaminedCallWithSameBytes,
		{0},
		{0},
		{},
		unstableMemberIds),
		"the same unaligned bytes inside unexamined source text are not a native id reference");
	check(!e2txt::NativeExpressionReferenceSlotsContainAnyEvidenceId(
		std::vector<std::uint8_t>{0x38, 0x44, 0x2C, 0x09, 0x42},
		{},
		{},
		{},
		unstableMemberIds) &&
		!e2txt::NativeExpressionReferenceSlotsContainAnyEvidenceId(
			{},
			{},
			{},
			{},
			unstableMemberIds),
		"bytes outside proven reference slots and empty expressions may retain their snapshots");

	const std::string ownerKey = "73:ImportedClass";
	std::vector<e2txt::NativePublicDeclarationOccurrence> publicOwners = {{0, ownerKey}};
	check(e2txt::IsUniquePublicDeclarationForDependency(publicOwners, 0, ownerKey),
		"one public owner declaration must authorize its dependency");
	publicOwners.push_back({1, ownerKey});
	check(!e2txt::IsUniquePublicDeclarationForDependency(publicOwners, 0, ownerKey) &&
		!e2txt::IsUniquePublicDeclarationForDependency(publicOwners, 1, ownerKey),
		"the same public owner in two dependencies must authorize neither");
	std::vector<e2txt::NativePublicDeclarationOccurrence> publicStructs = {
		{0, "WindowOptions:(Title:text)"},
		{1, "WindowOptions:(Title:int)"},
	};
	check(e2txt::IsUniquePublicDeclarationForDependency(
		publicStructs, 0, "WindowOptions:(Title:text)"),
		"same-named structs with different member signatures remain distinct declarations");
	publicStructs.push_back({1, "WindowOptions:(Title:text)"});
	check(!e2txt::IsUniquePublicDeclarationForDependency(
		publicStructs, 0, "WindowOptions:(Title:text)"),
		"the same public struct declaration across dependencies must fail closed");
	std::vector<e2txt::NativePublicDeclarationOccurrence> publicMethods = {
		{0, "ImportedClass:Initialize:(text)->bool"},
		{1, "ImportedClass:Initialize:(int)->bool"},
	};
	check(e2txt::IsUniquePublicDeclarationForDependency(
		publicMethods, 0, "ImportedClass:Initialize:(text)->bool"),
		"different method signatures remain distinct public declarations");
	publicMethods.push_back({1, "ImportedClass:Initialize:(text)->bool"});
	check(!e2txt::IsUniquePublicDeclarationForDependency(
		publicMethods, 0, "ImportedClass:Initialize:(text)->bool"),
		"the same owner, name, and signature across dependencies must fail closed");
	check(ownerKey != "9:ImportedClass",
		"the same public owner name with a different native class kind must remain distinct");
	check(e2txt::CanRecoverUnassignedDependencySymbols(true, true, true, 1),
		"trusted native bytes, complete public declarations, and a partial range authorize recovery");
	check(!e2txt::CanRecoverUnassignedDependencySymbols(true, true, true, 0) &&
		!e2txt::CanRecoverUnassignedDependencySymbols(false, true, true, 1) &&
		!e2txt::CanRecoverUnassignedDependencySymbols(true, false, true, 1) &&
		!e2txt::CanRecoverUnassignedDependencySymbols(true, true, false, 1),
		"zero ranges, missing trusted bytes, an unreadable public dependency, or untrusted definedIds must disable recovery");

	std::vector<std::int32_t> strictOwnedIds;
	std::vector<std::int32_t> strictChildIds;
	check(e2txt::CollectStrictNativeOwnedIds(
		0x41092C43,
		static_cast<std::int32_t>(0x41000000u),
		std::vector<std::int32_t>{0x42092C44},
		std::vector<e2txt::NativeDependencyStructMemberSymbol>{{0x42092C44, -2147483644, 0, "Title", {}}},
		static_cast<std::int32_t>(0x42000000u),
		strictOwnedIds,
		strictChildIds) && strictOwnedIds.size() == 2 && strictChildIds.size() == 1,
		"compact and detailed child evidence must agree exactly before host IDs are reserved");
	check(!e2txt::CollectStrictNativeOwnedIds(
		0x41092C43,
		static_cast<std::int32_t>(0x41000000u),
		std::vector<std::int32_t>{},
		std::vector<e2txt::NativeDependencyStructMemberSymbol>{{0x42092C44, -2147483644, 0, "Title", {}}},
		static_cast<std::int32_t>(0x42000000u),
		strictOwnedIds,
		strictChildIds) &&
		!e2txt::CollectStrictNativeOwnedIds(
			0x41092C43,
			static_cast<std::int32_t>(0x41000000u),
			std::vector<std::int32_t>{0},
			std::vector<e2txt::NativeDependencyStructMemberSymbol>{{0, -2147483644, 0, "Title", {}}},
			static_cast<std::int32_t>(0x42000000u),
			strictOwnedIds,
			strictChildIds) &&
		!e2txt::CollectStrictNativeOwnedIds(
			0x41092C43,
			static_cast<std::int32_t>(0x41000000u),
			std::vector<std::int32_t>{0x42092C44},
			std::vector<e2txt::NativeDependencyStructMemberSymbol>{{0x42092C45, -2147483644, 0, "Title", {}}},
			static_cast<std::int32_t>(0x42000000u),
			strictOwnedIds,
			strictChildIds) &&
		!e2txt::CollectStrictNativeOwnedIds(
			0x41092C43,
			static_cast<std::int32_t>(0x41000000u),
			std::vector<std::int32_t>{0x25092C44},
			std::vector<e2txt::NativeDependencyStructMemberSymbol>{{0x25092C44, -2147483644, 0, "Title", {}}},
			static_cast<std::int32_t>(0x42000000u),
			strictOwnedIds,
			strictChildIds),
		"missing, zero, mismatched, or wrong-category child IDs must reject the whole native evidence group");

	e2txt::NativeChildIdRegistry childRegistry;
	childRegistry.ObserveOccupied(0x25010001);
	check(childRegistry.TryReserveGroup(
		std::vector<std::int32_t>{0x25010002}, static_cast<std::int32_t>(0x25000000u), 1),
		"a valid recovered child group must reserve atomically");
	check(!childRegistry.TryClaimSequential(0x25010001, static_cast<std::int32_t>(0x25000000u), 1) &&
		!childRegistry.TryClaimSequential(0x25010002, static_cast<std::int32_t>(0x25000000u), 1) &&
		!childRegistry.TryReserveGroup(
			std::vector<std::int32_t>{0x25010002}, static_cast<std::int32_t>(0x25000000u), 2) &&
		!childRegistry.TryClaimPreferred(0x25010002, static_cast<std::int32_t>(0x25000000u), 2) &&
		childRegistry.TryClaimPreferred(0x25010002, static_cast<std::int32_t>(0x25000000u), 1),
		"all dependency cursors must skip occupied/reserved IDs and only the reserving row may consume a preferred ID");
	check(!childRegistry.TryClaimPreferred(0x25010002, static_cast<std::int32_t>(0x25000000u), 1) &&
		!childRegistry.TryReserveGroup(
			std::vector<std::int32_t>{0x42000000}, static_cast<std::int32_t>(0x42000000u), 1),
		"claimed IDs and exhausted zero-number child IDs must remain unavailable");
	check(e2txt::CanCollectUnassignedNativeDependencySymbol(e2txt::NativeUnassignedSymbolKind::Class) &&
		!e2txt::CanCollectUnassignedNativeDependencySymbol(e2txt::NativeUnassignedSymbolKind::Constant),
		"constants must never enter the unassigned dependency recovery pool");

	const e2txt::NativeDependencyMethodShape methodShape = {
		"bool",
		{{"text", 0x2, {0}}},
	};
	auto wrongKindShape = methodShape;
	wrongKindShape.params[0].attr = 0;
	auto wrongBoundsShape = methodShape;
	wrongBoundsShape.params[0].arrayBounds = {1};
	auto wrongReturnShape = methodShape;
	wrongReturnShape.returnTypeName = "int";
	check(methodShape != wrongKindShape && methodShape != wrongBoundsShape && methodShape != wrongReturnShape,
		"method evidence must distinguish by-ref/optional/array attributes, bounds, and return type");

	const auto normalizeRangeType = [](const std::int32_t id) {
		const std::int32_t type = id & static_cast<std::int32_t>(0xFF000000u);
		if (type == static_cast<std::int32_t>(0x18000000u) ||
			type == static_cast<std::int32_t>(0x28000000u) ||
			type == static_cast<std::int32_t>(0x38000000u)) {
			return static_cast<std::int32_t>(0x18000000u);
		}
		return type == static_cast<std::int32_t>(0x49000000u) ||
			type == static_cast<std::int32_t>(0x09000000u) ||
			type == static_cast<std::int32_t>(0x19000000u)
			? static_cast<std::int32_t>(0x49000000u)
			: type;
	};
	check(e2txt::ValidateNativeDependencyRanges(
		std::vector<e2txt::NativeDependencyRangeEvidence>{
			{0x49010000, 2, 0},
			{0x09010002, 2, 1},
		},
		normalizeRangeType),
		"distinct class-table starts remain valid after symmetric type normalization");
	check(e2txt::ValidateNativeDependencyRanges(
		std::vector<e2txt::NativeDependencyRangeEvidence>{
			{0x49010000, 3, 0},
			{0x09010002, 2, 1},
		},
		normalizeRangeType),
		"numeric overlap is irrelevant because counts address ordered table entries");
	check(e2txt::ValidateNativeDependencyRanges(
		std::vector<e2txt::NativeDependencyRangeEvidence>{{0x04FFFFFE, 3, 0}},
		normalizeRangeType),
		"a count may cross the numeric id boundary because it is not an id interval");
	check(!e2txt::ValidateNativeDependencyRanges(
		std::vector<e2txt::NativeDependencyRangeEvidence>{
			{0x49010000, 2, 0},
			{0x09010000, 1, 1},
		},
		normalizeRangeType),
		"two dependencies cannot claim the same normalized table start");
	check(!e2txt::ValidateNativeDependencyRanges(
		std::vector<e2txt::NativeDependencyRangeEvidence>{{0x04010000, 0, 0}},
		normalizeRangeType),
		"a zero-length defined-id range must fail closed");
	check(e2txt::SelectNativeDependencyOwner({
		e2txt::NativeDependencyOwnerCandidateEvidence{3, false, true},
	}) == std::optional<size_t>{3},
		"a sole re-export range must own all of its ordered entries, not only its start");
	check(e2txt::SelectNativeDependencyOwner({
		e2txt::NativeDependencyOwnerCandidateEvidence{2, false, false},
		e2txt::NativeDependencyOwnerCandidateEvidence{4, true, true},
	}) == std::optional<size_t>{4},
		"an exact range start must win an overlap even when the other record is direct");
	check(e2txt::SelectNativeDependencyOwner({
		e2txt::NativeDependencyOwnerCandidateEvidence{2, false, false},
		e2txt::NativeDependencyOwnerCandidateEvidence{4, false, true},
	}) == std::optional<size_t>{2} &&
		!e2txt::SelectNativeDependencyOwner({
			e2txt::NativeDependencyOwnerCandidateEvidence{2, false, true},
			e2txt::NativeDependencyOwnerCandidateEvidence{4, false, true},
		}).has_value(),
		"overlap without an exact start needs exactly one non-re-export owner");
	check(e2txt::SelectNativeDependencyClassType(
			0x49000000,
			0x09010010) == 0x09000000 &&
		e2txt::SelectNativeDependencyClassType(
			0x49000000,
			0) == 0x49000000,
		"a canonical native class ID must preserve its class kind when exported text has a base-class field");
	std::vector<std::int32_t> stableEmissionOrder;
	check(e2txt::TryBuildNativeDependencyEmissionOrder(
			std::vector<std::int32_t>{0x41010002, 0x41010003, 0x41020001, 0x41010001},
			std::unordered_map<std::int32_t, size_t>{
				{0x41010001, 0},
				{0x41010002, 0},
				{0x41010003, 0},
			},
			std::vector<std::vector<std::int32_t>>{{0x41010001, 0x41010002, 0x41010003}},
			stableEmissionOrder) &&
		stableEmissionOrder == std::vector<std::int32_t>{
			0x41020001,
			0x41010001,
			0x41010002,
			0x41010003,
		},
		"local-first reorder must retain the dependency range start and circular table order");
	const std::vector<std::int32_t> originalClassTable = {
		0x49010010,
		0x09010020,
		0x19010030,
		0x09020001,
	};
	std::vector<std::int32_t> dependencyClassIds;
	std::vector<std::int32_t> reorderedClassTable;
	std::vector<std::int32_t> verifiedDependencyClassIds;
	check(e2txt::TryCollectNativeDependencyOrderedRange(
			0x49010010,
			3,
			originalClassTable,
			normalizeRangeType,
			dependencyClassIds) &&
		e2txt::TryBuildNativeDependencyEmissionOrder(
			originalClassTable,
			std::unordered_map<std::int32_t, size_t>{
				{0x49010010, 0},
				{0x09010020, 0},
				{0x19010030, 0},
			},
			std::vector<std::vector<std::int32_t>>{dependencyClassIds},
			reorderedClassTable) &&
		reorderedClassTable == std::vector<std::int32_t>{
			0x09020001,
			0x49010010,
			0x09010020,
			0x19010030,
		} &&
		e2txt::TryCollectNativeDependencyOrderedRange(
			0x49010010,
			3,
			reorderedClassTable,
			normalizeRangeType,
			verifiedDependencyClassIds) &&
		verifiedDependencyClassIds == dependencyClassIds,
		"class/static/form dependency ranges must keep the hidden start anchor after local-first reorder");
	std::vector<std::int32_t> orderedSparseIds = {
		0x4101078E,
		0x41010311,
		0x41010312,
		0x41010313,
	};
	std::vector<std::int32_t> collectedSparseIds;
	check(e2txt::TryCollectNativeDependencyOrderedRange(
			0x4101078E,
			3,
			orderedSparseIds,
			normalizeRangeType,
			collectedSparseIds) &&
		collectedSparseIds == std::vector<std::int32_t>{
			0x4101078E,
			0x41010311,
			0x41010312,
		},
		"defined-id count must retain sparse following entries from the native table");
	check(e2txt::TryCollectNativeDependencyOrderedRange(
			0x41010313,
			3,
			orderedSparseIds,
			normalizeRangeType,
			collectedSparseIds) &&
		collectedSparseIds == std::vector<std::int32_t>{
			0x41010313,
			0x4101078E,
			0x41010311,
		},
		"an ordered defined-id slice wraps at the native table boundary");
	check(!e2txt::TryCollectNativeDependencyOrderedRange(
			0x4101078E,
			5,
			orderedSparseIds,
			normalizeRangeType,
			collectedSparseIds),
		"an ordered defined-id slice that exceeds its native table must fail closed");
	const std::vector<std::int32_t> orderedResourceIds = {
		0x18010001,
		0x28010002,
		0x38010003,
		0x18010004,
	};
	check(e2txt::TryCollectNativeDependencyOrderedRange(
			0x18010001,
			3,
			orderedResourceIds,
			normalizeRangeType,
			collectedSparseIds) &&
		collectedSparseIds == std::vector<std::int32_t>{
			0x18010001,
			0x28010002,
			0x38010003,
		},
		"the native resource slot must span value constants, images, and sounds in table order");
	std::int32_t highWater = 0xFFFF;
	const std::unordered_set<std::int32_t> claimedEvidenceIds = {
		0,
		0x04010001,
		0x25020002,
	};
	e2txt::ObserveClaimedNativeEvidenceIds(
		claimedEvidenceIds,
		[&](const std::int32_t id) { highWater = (std::max)(highWater, id & 0x00FFFFFF); });
	check(highWater == 0x020002 && !claimedEvidenceIds.contains(0x0A0ABCDE),
		"only claimed recovered ids may raise allocation; an unrelated high unassigned candidate must be ignored");
	const std::int32_t preservedHeaderHighWater = 0x035000;
	e2txt::ObserveNativeProgramHeaderHighWater(
		preservedHeaderHighWater,
		[&](const std::int32_t id) { highWater = (std::max)(highWater, id & 0x00FFFFFF); });
	const std::int32_t newlyAllocatedNumber = ++highWater;
	check(newlyAllocatedNumber > preservedHeaderHighWater,
		"adding a symbol must allocate above a preserved header high-water mark even when live ids are lower");
	check(e2txt::SelectNativeProgramHeaderHighWater(0x020000, 0x035000) == 0x035000 &&
		e2txt::SelectNativeProgramHeaderHighWater(0x040000, 0x035000) == 0x040000 &&
		e2txt::SelectNativeProgramHeaderHighWater(0x020000, std::nullopt) == 0x020000,
		"the persistent high-water mark must not depend on whether other program-header fields are reusable");
	const auto unemittedCrossReferences = e2txt::CollectUnemittedNativeEvidenceIds(
		std::unordered_set<std::int32_t>{0x49010001, 0x52010002, 0x04010003},
		std::unordered_set<std::int32_t>{0x49010001});
	check(!unemittedCrossReferences.contains(0x49010001) &&
		unemittedCrossReferences.contains(0x52010002) &&
		unemittedCrossReferences.contains(0x04010003),
		"form links and method-owner links are references and must not count as emitted definitions");

	using FormEvidence = e2txt::NativeFormElementIdentityEvidence;
	check(e2txt::SelectUniqueNativeFormElementIdentity({
		FormEvidence{0, true, false, false},
		FormEvidence{1, false, true, true},
	}) == std::optional<std::size_t>{0},
		"an exact form-control type match must win before evidence fallback");
	check(e2txt::SelectUniqueNativeFormElementIdentity({
		FormEvidence{3, false, true, true},
	}) == std::optional<std::size_t>{3},
		"a unique declaration match proven by an owner method reference may retain its native identity");
	check(!e2txt::SelectUniqueNativeFormElementIdentity({
		FormEvidence{0, false, true, false},
	}).has_value() &&
		!e2txt::SelectUniqueNativeFormElementIdentity({
			FormEvidence{0, false, false, true},
		}).has_value(),
		"a name or reference alone must not authorize a mismatched native control type");
	check(!e2txt::SelectUniqueNativeFormElementIdentity({
		FormEvidence{0, true, false, false},
		FormEvidence{1, true, false, false},
	}).has_value() &&
		!e2txt::SelectUniqueNativeFormElementIdentity({
			FormEvidence{0, false, true, true},
			FormEvidence{1, false, true, true},
		}).has_value(),
		"ambiguous exact or evidence-backed form-control candidates must fail closed");

	using MethodEvidence = e2txt::SupplementalNativeMethodIdentityEvidence;
	check(e2txt::DoesSupplementalNativeMethodTextIdentityMatch(
		"same-body-public", "same-body-private", "same-body-public", false),
		"a public-flag-only edit must keep full native method text identity");
	check(!e2txt::DoesSupplementalNativeMethodTextIdentityMatch(
		"old-body-public", "new-body-private", "new-body-public", false) &&
		!e2txt::DoesSupplementalNativeMethodTextIdentityMatch(
			"", "same-body-private", "same-body-public", false),
		"changed method text or a missing native digest must not prove identity");
	check(e2txt::ApplyParsedMethodPublicityToNativeAttr(0x30, true) == 0x38 &&
		e2txt::ApplyParsedMethodPublicityToNativeAttr(0x38, false) == 0x30,
		"the rebuilt method attr must take its public bit from current text and retain other native bits");
	check(e2txt::SelectUniqueSupplementalNativeMethodIdentity({
		MethodEvidence{4, true, true, true, true, true, true},
	}, false) == std::optional<std::size_t>{4},
		"a unique method whose full text matches after restoring native publicity may retain its identity");
	check(!e2txt::SelectUniqueSupplementalNativeMethodIdentity({
		MethodEvidence{4, true, true, true, true, true, true},
	}, true).has_value(),
		"supplemental method evidence must not replace a method already present in the trusted donor");
	check(!e2txt::SelectUniqueSupplementalNativeMethodIdentity({
		MethodEvidence{0, true, true, true, true, true, false},
		MethodEvidence{1, false, true, true, true, true, true},
		MethodEvidence{2, true, true, false, true, true, true},
		MethodEvidence{3, true, true, true, false, true, true},
	}, false).has_value(),
		"zero addresses, another owner, a declaration mismatch, or changed method text must reject supplemental identity");
	check(!e2txt::SelectUniqueSupplementalNativeMethodIdentity({
		MethodEvidence{0, true, true, true, true, true, true},
		MethodEvidence{1, true, true, true, true, true, true},
	}, false).has_value(),
		"ambiguous complete native-map method identities must fail closed");

	std::cout << "failures=" << failures << '\n';
	return failures == 0 ? 0 : 1;
}
