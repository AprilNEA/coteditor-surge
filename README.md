# Surge for CotEditor

为 CotEditor 7 提供 Surge 配置、模块和规则集的语法高亮、大纲和检查脚本。检查脚本调用本机 Surge 的离线语言服务，结果显示在 CotEditor 控制台。

## 安装

需要 CotEditor 7 或更新版本，安装位置必须是 `/Applications/CotEditor.app`。诊断功能还需要支持 `lsp` 命令的 Surge Mac 6.10.0 或更新版本，安装位置必须是 `/Applications/Surge.app`。仅使用语法高亮和大纲时不需要 Surge。

推荐通过 Homebrew 安装：

```sh
brew install --cask AprilNEA/tap/coteditor-surge
```

发布包包含支持 Apple Silicon 和 Intel 的 Swift 可执行文件，只使用 macOS 系统库。安装和运行都不需要 Python 或 Swift 编译器。Homebrew 管理语法包和脚本的升级、卸载，CotEditor 和 Surge 由你单独安装。

如果已经手动安装，先把以下两个目录移到备份位置，再执行 Homebrew 安装命令。安装器会拒绝覆盖已有目录，也不会自动接管手动安装的文件。

- `~/Library/Containers/com.coteditor.CotEditor/Data/Library/Application Support/CotEditor/Syntaxes/Surge.cotsyntax`
- `~/Library/Application Scripts/com.coteditor.CotEditor/Surge`

也可以从 [Release](https://github.com/AprilNEA/coteditor-surge/releases) 下载 `coteditor-surge-<版本>.tar.gz`，解压后进入发布包目录，使用系统 shell 安装：

```sh
/bin/sh install.sh
```

GitHub 自动生成的源码包不包含可执行文件。源码构建方法见「开发」。

若 CotEditor 已经打开，在「Settings → Format」列表下方的菜单中执行「Reload All Syntaxes」，加载新语法。

## 使用

1. 打开 Surge 文件。`.sgconf`、`.dconf`、`.sgmodule`、`.sgruleset` 和 `Surge.conf` 自动使用「Surge」语法。
2. 对其他 `.conf`、`.list` 或 `.txt` 文件，在工具栏手动选择「Surge」。
3. 执行「Script → Surge → Check Surge」，检查当前文本，包括未保存的修改和未命名文档。

显式保存使用「Surge」语法的文档时，会自动检查磁盘上的 UTF-8 文件。控制台显示文件名、行号、列号、诊断级别和消息；行号、列号从 1 开始，列号使用 LSP 的 UTF-16 单位。检查不会改写文档、切换 Surge 配置或连接 Controller。

诊断器根据扩展名、模块头和规则行选择语言。在解压后的发布包目录中，也可以通过命令行指定语言：

```sh
./bin/check-surge --saved --language surge-ruleset examples/example.sgruleset
```

「Surge reported no diagnostics」仅表示服务端未返回诊断，不保证配置中的所有问题都已被检查。其他文档的未保存修改不会参与本次检查，外部规则集也不会自动完整检查。独立 `.dconf` 缺少主配置上下文，`DOMAIN-SET` 纯域名列表不属于规则集检查范围。

语法高亮使用正则表达式。行内注释使用 `# comment`、`; comment` 或 `// comment`；紧接内容的 `#comment` 和 `//comment` 行内注释可能不着色。诊断结果显示在控制台，编辑区不显示错误波浪线。

## 开发

开发需要 Xcode Command Line Tools（Swift 6 或更新版本）和 devenv。在普通终端执行以下命令；检查脚本通过 devenv 调用 shell 工具，Swift 编译器和格式检查使用 Xcode 工具链及对应 SDK：

```sh
/bin/sh scripts/check.sh
/bin/sh scripts/build-release.sh
```

构建脚本分别编译 `arm64` 和 `x86_64`，合并为通用可执行文件，再生成 `dist/coteditor-surge-<版本>-local.tar.gz`。最低系统版本是 macOS 15。GitHub Actions 在两种架构上执行检查并上传本地测试包。

本地测试包使用 ad hoc 签名，不能作为 Homebrew 发布包分发。正式发布时，指定 Developer ID Application 签名证书、已经配置的 `notarytool` Keychain profile 和存放凭据的钥匙串路径：

```sh
/bin/sh scripts/build-release.sh 'Developer ID Application: Your Name (TEAMID)' 'notary-profile' /path/to/signing.keychain-db
```

构建脚本使用 Hardened Runtime 和安全时间戳签名，再提交 Apple 公证。只有公证状态为 `Accepted` 时，才生成不带 `-local` 后缀的正式发布包并输出 SHA-256。把正式发布包上传到 Release，并将 SHA-256 填入 Cask。命令行可执行文件不支持附加公证票据，首次启动需要联网验证。

真实诊断集成测试需要本机 Surge；缺少 Surge 时跳过这部分测试。测试只使用合成配置，不读取个人配置。

## 卸载

Homebrew 安装使用以下命令升级或卸载：

```sh
brew upgrade --cask coteditor-surge
brew uninstall --cask coteditor-surge
```

卸载会把这套语法包和脚本移到废纸篓。升级会替换这两个目录，修改其中的文件前先保留副本。Surge 配置文件不受影响。

手动安装的版本，从 CotEditor「Settings → Format」删除「Surge」语法，再从「Script → Open Scripts Folder」移走 `Surge` 文件夹。自动保存检查脚本随文件夹一起移除。
