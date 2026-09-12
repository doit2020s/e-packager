#pragma once

#include <string_view>

namespace e2txt {

// 选择写回易模块原生记录的路径，并保留工程原始令牌。
enum class DependencyModulePathSource {
	Stored,
	Resolved,
	Workspace,
	Missing,
};

struct DependencyModulePathChoice {
	std::string_view path;
	DependencyModulePathSource source = DependencyModulePathSource::Missing;
};

inline DependencyModulePathChoice SelectDependencyModulePathForPersistence(
	const std::string_view storedPath,
	const std::string_view resolvedPath,
	const std::string_view workspaceSourcePath)
{
	// The native dependency record must retain the token authored by E, including
	// '$module.ec'. resolvedPath is lookup evidence and must not replace that token.
	if (!storedPath.empty()) {
		return { storedPath, DependencyModulePathSource::Stored };
	}
	if (!resolvedPath.empty()) {
		return { resolvedPath, DependencyModulePathSource::Resolved };
	}
	if (!workspaceSourcePath.empty()) {
		return { workspaceSourcePath, DependencyModulePathSource::Workspace };
	}
	return {};
}

} // namespace e2txt
