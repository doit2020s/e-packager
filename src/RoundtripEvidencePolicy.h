#pragma once

#include <string_view>
#include "../thirdparty/json.hpp"

namespace e2txt {

// 来源文件哈希与原生快照属于重建证据；工程语义由独立 bundle 比较验证。
inline bool IsRoundtripEvidenceFile(std::string_view relativePath)
{
	return relativePath == "AGENTS.md" ||
		relativePath.starts_with("src/.native_") ||
		relativePath == "project/.native_source.bin" ||
		relativePath == "project/.native_source_map.json" ||
		relativePath == "project/.native_symbol_map.json";
}

// 只移除根 info.json 的文件来源字段，不影响资源或依赖中的同名字段。
inline void NormalizeRoundtripSourceInfo(nlohmann::json& value, std::string_view relativePath)
{
	if (relativePath != "info.json" || !value.is_object()) return;
	value.erase("sourceMd5");
	value.erase("sourceSize");
}

} // namespace e2txt
