#include "SourceArrayFormatValidator.h"

#include <Windows.h>

#include <algorithm>
#include <cctype>
#include <sstream>

namespace e2txt {

namespace {

std::string LocalText(const wchar_t* text)
{
	if (text == nullptr || *text == L'\0') {
		return {};
	}
	const int length = WideCharToMultiByte(CP_ACP, 0, text, -1, nullptr, 0, nullptr, nullptr);
	if (length <= 1) {
		return {};
	}
	std::string result(static_cast<size_t>(length), '\0');
	WideCharToMultiByte(CP_ACP, 0, text, -1, result.data(), length, nullptr, nullptr);
	result.pop_back();
	return result;
}

std::string LocalToUtf8(const std::string& text)
{
	if (text.empty()) {
		return {};
	}
	const int wideLength = MultiByteToWideChar(CP_ACP, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
	if (wideLength <= 0) {
		return text;
	}
	std::wstring wide(static_cast<size_t>(wideLength), L'\0');
	if (MultiByteToWideChar(CP_ACP, 0, text.data(), static_cast<int>(text.size()), wide.data(), wideLength) <= 0) {
		return text;
	}
	const int utf8Length = WideCharToMultiByte(CP_UTF8, 0, wide.data(), wideLength, nullptr, 0, nullptr, nullptr);
	if (utf8Length <= 0) {
		return text;
	}
	std::string result(static_cast<size_t>(utf8Length), '\0');
	WideCharToMultiByte(CP_UTF8, 0, wide.data(), wideLength, result.data(), utf8Length, nullptr, nullptr);
	return result;
}

std::string TrimCopy(const std::string& text)
{
	size_t begin = 0;
	size_t end = text.size();
	while (begin < end && std::isspace(static_cast<unsigned char>(text[begin])) != 0) {
		++begin;
	}
	while (end > begin && std::isspace(static_cast<unsigned char>(text[end - 1])) != 0) {
		--end;
	}
	return text.substr(begin, end - begin);
}

bool StartsWith(const std::string& text, const std::string& prefix)
{
	return text.size() >= prefix.size() && text.compare(0, prefix.size(), prefix) == 0;
}

std::vector<std::string> SplitCommaFields(const std::string& text)
{
	std::vector<std::string> fields;
	size_t start = 0;
	bool inQuote = false;
	for (size_t index = 0; index < text.size(); ++index) {
		if (text[index] == '"') {
			inQuote = !inQuote;
		}
		else if (text[index] == ',' && !inQuote) {
			fields.push_back(TrimCopy(text.substr(start, index - start)));
			start = index + 1;
		}
	}
	fields.push_back(TrimCopy(text.substr(start)));
	return fields;
}

bool IsValidArrayDimensions(const std::string& field)
{
	const std::string text = TrimCopy(field);
	if (text.size() < 3 || text.front() != '"' || text.back() != '"') {
		return false;
	}
	const std::string dimensions = text.substr(1, text.size() - 2);
	if (dimensions.empty()) {
		return false;
	}
	size_t start = 0;
	while (start <= dimensions.size()) {
		const size_t comma = dimensions.find(',', start);
		const std::string part = TrimCopy(dimensions.substr(
			start,
			comma == std::string::npos ? std::string::npos : comma - start));
		const bool omittedLeadingDimension = start == 0 && comma != std::string::npos && part.empty();
		if ((!omittedLeadingDimension && part.empty()) ||
			!std::all_of(part.begin(), part.end(), [](const unsigned char ch) {
				return std::isdigit(ch) != 0;
			})) {
			return false;
		}
		if (comma == std::string::npos) {
			break;
		}
		start = comma + 1;
	}
	return true;
}

std::string StripCommentOutsideQuotes(const std::string& line)
{
	const std::string openQuote = LocalText(L"“");
	const std::string closeQuote = LocalText(L"”");
	bool inChineseQuote = false;
	bool inAsciiQuote = false;
	for (size_t index = 0; index < line.size(); ++index) {
		if (!inAsciiQuote && line.compare(index, openQuote.size(), openQuote) == 0) {
			inChineseQuote = true;
			index += openQuote.size() - 1;
			continue;
		}
		if (!inAsciiQuote && line.compare(index, closeQuote.size(), closeQuote) == 0) {
			inChineseQuote = false;
			index += closeQuote.size() - 1;
			continue;
		}
		if (!inChineseQuote && line[index] == '"') {
			inAsciiQuote = !inAsciiQuote;
			continue;
		}
		if (!inChineseQuote && !inAsciiQuote && line[index] == '\'') {
			return line.substr(0, index);
		}
	}
	return line;
}

void AddIssue(
	SourceArrayFormatReport& report,
	const std::string& localPath,
	const size_t line,
	const char* rule,
	const char* message)
{
	report.errors.push_back(SourceArrayFormatDiagnostic {LocalToUtf8(localPath), line, rule, message});
}

void CheckSourceText(
	const std::string& path,
	const std::string& sourceTextLocal,
	SourceArrayFormatReport& report)
{
	const std::string localVariable = LocalText(L".局部变量");
	const std::string assemblyVariable = LocalText(L".程序集变量");
	const std::string globalVariable = LocalText(L".全局变量");
	const std::string member = LocalText(L".成员");
	const std::string subprogram = LocalText(L".子程序");
	const std::string array = LocalText(L"数组");
	const std::vector<std::string> variablePrefixes = {
		localVariable,
		assemblyVariable,
		globalVariable,
		member,
	};

	++report.checkedFiles;
	size_t start = 0;
	size_t line = 1;
	while (start <= sourceTextLocal.size()) {
		size_t end = sourceTextLocal.find('\n', start);
		if (end == std::string::npos) {
			end = sourceTextLocal.size();
		}
		std::string rawLine = sourceTextLocal.substr(start, end - start);
		if (!rawLine.empty() && rawLine.back() == '\r') {
			rawLine.pop_back();
		}
		++report.checkedLines;

		const std::string codeLine = TrimCopy(StripCommentOutsideQuotes(rawLine));
		for (const std::string& prefix : variablePrefixes) {
			if (!StartsWith(codeLine, prefix)) {
				continue;
			}
			const std::vector<std::string> fields = SplitCommaFields(codeLine.substr(prefix.size()));
			if (fields.size() >= 3 && fields[2] == array) {
				AddIssue(
					report,
					path,
					line,
					"bad_array_variable_declaration",
					"array dimensions belong in the fourth declaration field");
			}
			if (fields.size() >= 4 && !fields[3].empty() && !IsValidArrayDimensions(fields[3])) {
				AddIssue(
					report,
					path,
					line,
					"bad_array_dimension_field",
					"array dimensions must be a quoted non-negative integer list");
			}
			break;
		}

		if (StartsWith(codeLine, subprogram)) {
			const std::vector<std::string> fields = SplitCommaFields(codeLine.substr(subprogram.size()));
			const bool thirdFieldArray = fields.size() >= 3 && fields[2] == array;
			const bool fourthFieldArray = fields.size() >= 4 && fields[2].empty() && fields[3] == array;
			if (thirdFieldArray || fourthFieldArray) {
				AddIssue(
					report,
					path,
					line,
					"bad_array_return_declaration",
					"subprogram array returns must use a reference array parameter or structure member");
			}
		}

		if (end == sourceTextLocal.size()) {
			break;
		}
		start = end + 1;
		++line;
	}
}

}  // namespace

bool SourceArrayFormatReport::IsValid() const
{
	return errors.empty();
}

SourceArrayFormatReport ValidateProjectBundleArrayFormat(const ProjectBundle& bundle)
{
	SourceArrayFormatReport report;
	CheckSourceText(LocalText(L"src/.全局变量.txt"), bundle.globalText, report);
	CheckSourceText(LocalText(L"src/.数据类型.txt"), bundle.dataTypeText, report);
	for (const BundleSourceFile& file : bundle.sourceFiles) {
		CheckSourceText(file.relativePath, file.content, report);
	}
	return report;
}

std::string FormatSourceArrayFormatReport(const SourceArrayFormatReport& report)
{
	std::ostringstream stream;
	stream << "source_array_format_error: count=" << report.errors.size();
	for (const SourceArrayFormatDiagnostic& diagnostic : report.errors) {
		stream << "\nsource_array_format_error: file=" << diagnostic.filePath
			<< ", line=" << diagnostic.line
			<< ", rule=" << diagnostic.rule
			<< ", detail=" << diagnostic.message;
	}
	return stream.str();
}

}  // namespace e2txt
