#include "../src/RoundtripEvidencePolicy.h"
#include "../src/NativeDependencyEvidencePolicy.h"
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
		{0x4908A4CE, 0, -1, "ImportedClass"},
	};
	const auto classMatches = [](const e2txt::NativeDependencyClassSymbol& item) {
		return item.name == "ImportedClass";
	};
	const auto* importedClass = e2txt::SelectUniqueUnassignedNativeDependencySymbol(
		classes, noIds, noIds, classMatches);
	check(importedClass != nullptr && importedClass->id == 0x4908A4CE,
		"unique imported class evidence must retain its host-native id");
	classes.push_back({0x4908A4CF, 0, -1, "ImportedClass"});
	check(e2txt::SelectUniqueUnassignedNativeDependencySymbol(
		classes, noIds, noIds, classMatches) == nullptr,
		"duplicate imported owner names must not authorize either id");
	classes.resize(1);
	const std::unordered_set<std::int32_t> occupiedClassIds = {0x4908A4CE};
	check(e2txt::SelectUniqueUnassignedNativeDependencySymbol(
		classes, occupiedClassIds, noIds, classMatches) == nullptr,
		"an imported owner id occupied by a local snapshot must not be authorized");
	classes.push_back({0x4908A4CF, 0, -1, "ImportedClass"});
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
		"adjacent class-like ranges remain valid after symmetric type normalization");
	check(!e2txt::ValidateNativeDependencyRanges(
		std::vector<e2txt::NativeDependencyRangeEvidence>{
			{0x49010000, 3, 0},
			{0x09010002, 2, 1},
		},
		normalizeRangeType),
		"overlapping class-like ranges across records must fail closed");
	check(!e2txt::ValidateNativeDependencyRanges(
		std::vector<e2txt::NativeDependencyRangeEvidence>{{0x04FFFFFE, 3, 0}},
		normalizeRangeType),
		"a defined-id range that overflows the 24-bit id number must fail closed");
	check(!e2txt::ValidateNativeDependencyRanges(
		std::vector<e2txt::NativeDependencyRangeEvidence>{{0x04010000, 0, 0}},
		normalizeRangeType),
		"a zero-length defined-id range must fail closed");
	std::int32_t highWater = 0xFFFF;
	e2txt::ObserveNonZeroNativeEvidenceIds(
		std::vector<std::int32_t>{0, 0x04010001, 0x0A0ABCDE},
		[&](const std::int32_t id) { highWater = (std::max)(highWater, id & 0x00FFFFFF); });
	check(highWater == 0x0ABCDE,
		"all non-zero recovered ids, including child parameter ids, must raise the allocation high-water mark");

	std::cout << "failures=" << failures << '\n';
	return failures == 0 ? 0 : 1;
}
