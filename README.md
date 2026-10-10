# Surge for CotEditor

为 CotEditor 7 提供 Surge 配置、模块和规则集的语法高亮、大纲和检查脚本。检查脚本调用本机 Surge 的离线语言服务，结果显示在 CotEditor 控制台。

## 安装

需要 CotEditor 7、Python 3.11 或更新版本，以及支持 `lsp` 命令的 Surge Mac 6.10.0 或更新版本。Surge 必须安装在 `/Applications/Surge.app`。

```sh
python3 install.py
```

安装程序使用当前 Python 的绝对路径，避免 CotEditor 与终端的 `PATH` 不同。保留这个 Python 安装。若已有同名语法或脚本目录，安装程序会停止，不覆盖已有文件。

若 CotEditor 已经打开，在「Settings → Format」列表下方的菜单中执行「Reload All Syntaxes」，加载新语法。

## 使用

1. 打开 Surge 文件。`.sgconf`、`.dconf`、`.sgmodule`、`.sgruleset` 和 `Surge.conf` 自动使用「Surge」语法。
2. 对其他 `.conf`、`.list` 或 `.txt` 文件，在工具栏手动选择「Surge」。
3. 执行「Script → Surge → Check Surge」，检查当前文本，包括未保存的修改和未命名文档。

显式保存使用「Surge」语法的文档时，会自动检查磁盘上的 UTF-8 文件。控制台显示文件名、行号、列号、诊断级别和消息；行号、列号从 1 开始，列号使用 LSP 的 UTF-16 单位。检查不会改写文档、切换 Surge 配置或连接 Controller。

检查脚本根据扩展名、模块头和规则行选择语言。命令行可以指定语言，例如：

```sh
python3 scripts/check-surge.py --saved --language surge-ruleset examples/example.sgruleset
```

「Surge reported no diagnostics」仅表示服务端未返回诊断，不保证配置中的所有问题都已被检查。其他文档的未保存修改不会参与本次检查，外部规则集也不会自动完整检查。独立 `.dconf` 缺少主配置上下文，`DOMAIN-SET` 纯域名列表不属于规则集检查范围。

语法高亮使用正则表达式。行内注释使用 `# comment`、`; comment` 或 `// comment`；紧接内容的 `#comment` 和 `//comment` 行内注释可能不着色。诊断结果显示在控制台，编辑区不显示错误波浪线。

## 开发

```sh
devenv shell
ruff check .
ruff format --check .
python -m unittest discover -s tests -v
xcrun swift-format lint --strict tests/check-syntax.swift
swift tests/check-syntax.swift .
```

集成测试需要本机 Surge。测试只使用合成配置，不读取个人配置。

## 卸载

从 CotEditor「Settings → Format」删除「Surge」语法，再从「Script → Open Scripts Folder」移走 `Surge` 文件夹。自动保存检查脚本随文件夹一起移除。
