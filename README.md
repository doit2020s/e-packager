# e-packager

将易语言 `.e` / `.ec` 文件解包为可读目录，或将目录回包为 `.e`，让易语言项目享有 Git 版本管理、代码 Diff、AI 辅助编辑等现代开发体验。

当前 AutoLinker 定制版为 `1.2.8-autolinker.3`。它以官方 `v1.2.8` 的解包/回包修复为同步基线，保留数组专用检查、原生结构与支持库符号保真。已合入布尔常量、`.ec` 类型映射、工程子系统、旧新版事件表、匿名类型、行尾注释、方法快照、全角/半角运算符和字节集参数切分修复，并补齐新增全局变量、跨层继承、同名命令参数分派、支持库链式成员类型和修改后 `.ec` 安全回包所需的语义解析。

本定制版不包含官方后续加入的独立编译器、黑月编译路径、通用源码预检、`compile-check` 或支持库窗口属性探测器。窗口扩展属性继续按原始字节保留，避免独立进程装载 `RSCProject.fne`；实时窗口设计和权威编译由 AutoLinker Bridge/Service 负责。

> 📖 参考应用：[易语言 × AI Agent 实践白皮书](https://github.com/aiqinxuancai/Awesome-E-Agent)
> 
> 📖 [易语言AutoLinker支持库，提供**无头编译**，用于AI使用本项目编辑代码后的验证编译](https://github.com/aiqinxuancai/AutoLinker)
>
> 📊 使用 AI 编辑易语言源码前，可参考[易语言大模型基准评分](https://e-language-bench.apptest.dev)选择模型。

## 使用

### 解包

```
e-packager unpack <input.e|input.ec> <output-dir>
```

只需要解包主 `.e` / `.ec` 文件，不刷新依赖易模块工作区和支持库公开接口时，可传入 `--main-only`：

```
e-packager unpack MyApp.e MyApp\ --main-only
```

如果源文件设置了打开密码，解包时传入 `--password`：

```
e-packager unpack MyApp.e MyApp\ --password 111222333
```

解包加密文件后，后续回包默认输出为未加密 `.e`，不需要再次提供密码；如果希望回包结果继续带打开密码，可在 `pack` 时传入 `--password`。

也可直接将 `.e` / `.ec` 文件拖放到 `e-packager.exe` 上，自动在源文件所在目录创建同名子目录并解包：

```
e-packager MyApp.e    # 解包到 MyApp\
e-packager MyMod.ec   # 解包到 MyMod\
```

### 支持库公开接口导出

Win32 版可直接读取 x86 `.fne` 支持库，并导出与解包 `.e` 时 `elib/*.txt` 一致的公开接口文本：

```
e-packager decrypt-fne MyLib.fne MyLib.txt
```

也可直接将 `.fne` 文件拖放到 `e-packager.exe` 上，默认在同目录生成同名 `.txt`。x64 版不会加载 x86 支持库，此命令会提示需要 Win32 版。

**解包目录结构：**

| 路径 | 内容 |
| --- | --- |
| `src/` | 源码文件（`.txt`）及窗口界面定义（`.xml`） |
| `project/` | 封包所需元数据；`.e` 解包后还可能含原生快照，**请勿删除** |
| `header/` | 仅 `.ec` 项目生成；公开接口头文件，不参与回包 |
| `ecom/` | 仅 `.e` 项目生成；每个子目录为一个已解包的模块工作区，不参与回包 |
| `elib/` | 依赖支持库的公开接口导出，仅供查阅，不参与回包 |
| `image/` | 图片资源及任意二进制资源，元数据在 `image/list.json` |
| `audio/` | 音频资源及任意二进制资源，元数据在 `audio/list.json` |
| `tool/e-packager.exe` | 随目录自带的封包工具 |
| `info.json` | 来源文件的类型、路径、修改时间、MD5 |
| `AGENTS.md` | 供 AI Agent 阅读的项目结构说明 |

若 `.e` 工程引用了易模块（`.ec`），默认解包时会自动将这些模块同步导出到 `ecom/<模块名>/`，并导出支持库公开接口到 `elib/`。`project/.module.json` 中对应依赖项会额外写入 `resolvedPath`（本机模块完整路径）与 `localWorkspace`（本地工作区目录）两个只读辅助字段，不参与回包。使用 `--main-only` 时不会生成、更新或删除 `ecom/` 与 `elib/`，也不会写入这些派生辅助字段。

### 回包

```
e-packager pack <input-dir> <output.e|output.ec> [--password <text>]
```

或在项目根目录（或 `tool/` 子目录）内直接运行，自动输出到 `pack/` 目录：

```
e-packager
```

> 未修改且仍写回原路径的 `.ec` 工作区可复用原生快照。只要文本发生修改或输出路径改变，必须输出为新的 `.e`，再使用易语言 5.9 编译为模块；工具会拒绝把语义重建结果伪装成 `.ec`。

需要为回包结果设置打开密码时：

```
e-packager pack MyApp\ MyApp-protected.e --password 111222333
```

### 回包前数组检查

可以只读取工作区并检查数组声明和数组返回格式，不生成 `.e` 文件：

```
e-packager validate <input-dir>
```

`pack` 和无参默认回包会自动执行同一检查。检查范围仅包含：变量声明第三字段误写 `数组`、数组维度字段格式，以及子程序返回声明误写数组。诊断包含源码文件、行号和稳定规则代码。

数组维度写在第四字段，例如 `.局部变量 arr, 整数型, , "0"`、`"2,3"` 或 `",4"`。参数第三字段中的 `参考 数组` 属于合法参数属性。非数组语法、类型、名称连接、窗口绑定和运行期问题不由 `validate` 拦截，应保留真实回包错误，并由易语言 IDE 或 AutoLinker 诊断。

新增或修改的可执行语句仍必须能够编码成真实易语言结构；编码失败会中止回包，不会伪造命令、常量或类型 ID。

开发版的解包/回包核心集中验收使用：

```powershell
.\tools\TestRoundtripCore.ps1
```

测试产物只写入仓库的 `.autolinker/work`，不会覆盖模板或用户工程。

### 支持库命令与 RSCProject

`RSCProject.dll` 只允许使用易语言安装根目录中的配套文件。e-packager 不内嵌、不释放，也不把它复制到工作区 `tool`、工程根目录或封包器旁边；不要把该运行时 DLL 当成工程的 `RSCProject.fne` 支持库。`RSCProject.fne` 不适合由独立封包进程反复加载；其公开名不可用时，解包和回包会原样保留 `_Lib<序号>Cmd<编号>` 与 `_Lib<序号>Const<编号>`。

新写语句中的裸函数名按“当前工程本地子程序、支持库命令、导入易模块子程序”的顺序绑定。这样可以避免精易模块等依赖里的同名公开子程序抢占系统核心支持库命令。例如 `取运行目录 ()` 应编码为系统核心支持库 `Lib0/Cmd65`，不能写成导入模块方法 ID。

如果一段新增程序集先复制到记事本、再粘贴进易语言 IDE 后恢复正常，说明纯文本通常没有损坏，而是 IDE 粘贴时重新完成了名称连接。这个现象可以用于定位，但不能作为交付流程；应修复封包器的符号绑定，并通过回包、重新解包和原生命令编号检查确认。

### 刷新派生内容

解包后，若依赖的易模块或支持库发生变化，或需要新增图片、音频等二进制资源，可用 `update` 命令刷新 `ecom/` 与 `elib/` 中的派生内容并写入资源索引，无需重新解包整个工程。

```
e-packager update <input-dir>
```

**示例：**

```
# 刷新工作区的所有 ecom/elib 派生内容
e-packager update MyApp\

# 新增一个 .ec 模块到 ecom/，并刷新其导出内容
e-packager update MyApp\ --add-ecom D:\modules\MyLib.ec

# 新增多个 .ec 模块
e-packager update MyApp\ --add-ecom D:\modules\Net.ec --add-ecom D:\modules\UI.ec

# 新增支持库（按文件名 stem，自动在 lib/ 目录中查找 .fne/.fnr/.dll）
# 仅 Win32 版 e-packager 支持此选项
e-packager update MyApp\ --add-elib 互联网支持库

# 也可直接传入 .fne 文件的完整路径
e-packager update MyApp\ --add-elib D:\易语言\lib\互联网支持库.fne

# 同时新增模块与支持库
e-packager update MyApp\ --add-ecom D:\modules\Net.ec --add-elib 互联网支持库

# 新增图片资源，默认使用文件名 stem 作为常量名，代码中写 #logo
e-packager update MyApp\ --add-image D:\res\logo.png

# 新增音频资源，默认使用文件名 stem 作为常量名，代码中写 #notify
e-packager update MyApp\ --add-audio D:\res\notify.wav

# 显式指定资源常量名，代码中写 #启动画面
e-packager update MyApp\ --add-image 启动画面=D:\res\splash.bin
```

`--add-image` 与 `--add-audio` 都写入易语言常量资源表，使用方式与普通常量一致，代码中以 `#资源名` 引用。目录名只是决定资源写入 `image/list.json` 还是 `audio/list.json`，实际内容可以是程序需要携带的任意二进制数据。

### 其他命令

```
# 从 GitHub Release 下载最新 e-packager 并替换当前 exe
e-packager /update

# 查看当前程序版本
e-packager version

# 导出单个 .fne 支持库公开接口（仅 Win32 版）
e-packager decrypt-fne <input.fne> [output.txt]

# 快速检查目录工程，不生成 .e
e-packager validate <input-dir>

# 比较原文件与目录内容是否一致
e-packager compare-bundle <input.e|input.ec> <input-dir> [--password <text>]

# 解包后立即回包（快速验证）
e-packager roundtrip <input.e|input.ec> <work-dir> <output.e|output.ec> [--password <text>]

# 往返并校验字节一致性
e-packager verify-roundtrip <input.e|input.ec> <work-dir> <output.e|output.ec> [--password <text>]
```

`/update` 会启动后台替换脚本：先查询 `aiqinxuancai/e-packager` 的最新 GitHub Release，下载匹配的 Win32 二进制压缩包，等待当前进程退出后替换当前 `e-packager.exe`。当前 GitHub Actions 不上传 x64 包，因此 x64 构建会跳过自更新。若需要在本地开发版或同版本上强制覆盖，可使用 `e-packager /update --force`。

## 注意

**使用前请备份源文件**，作者不对可能的数据损失负任何责任。遇到无法解包或回包的文件，欢迎提交 Issue 并附上文件。

## 致谢

- [OpenEpl/TextECode](https://github.com/OpenEpl/TextECode) — 易语言工程文件与文本代码互转
- [OpenEpl/EProjectFile](https://github.com/OpenEpl/EProjectFile) — 易语言项目文件读写库
