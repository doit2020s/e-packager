#pragma once

#include <cstddef>
#include <string>
#include <vector>

#include "e2txt.h"

namespace e2txt {

struct SourceArrayFormatDiagnostic {
	std::string filePath;
	size_t line = 0;
	std::string rule;
	std::string message;
};

struct SourceArrayFormatReport {
	size_t checkedFiles = 0;
	size_t checkedLines = 0;
	std::vector<SourceArrayFormatDiagnostic> errors;

	bool IsValid() const;
};

// Keep this validator aligned with AutoLinker's ELangArrayFormatChecker. It
// intentionally rejects only array declarations known to corrupt text import.
SourceArrayFormatReport ValidateProjectBundleArrayFormat(const ProjectBundle& bundle);

std::string FormatSourceArrayFormatReport(const SourceArrayFormatReport& report);

}  // namespace e2txt
