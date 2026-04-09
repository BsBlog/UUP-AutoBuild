# UUP AutoBuild

这个仓库提供一个 GitHub Actions 工作流，用来自动查询 UUP dump 上最新的 Windows 构建，并下载 UUP dump 官方生成的转换压缩包，直接运行包内 `uup_download_windows.cmd` 自动生成 ISO。

当前默认行为：

- 渠道：`RETAIL`、`WIF`、`WIS`、`CANARY`
- 语言：`zh-cn`、`en-us`
- 版本：`PROFESSIONAL`
- 架构：`amd64`、`arm64`
- 转换选项：
  - 集成更新
  - 运行组件清理
  - 集成 `.NET Framework 3.5`
  - 使用固实压缩 `ESD`

## 工作流说明

工作流文件：`.github/workflows/uup-autobuild.yml`

触发方式：

- 手动运行 `workflow_dispatch`
- 每天自动运行一次

为了避免重复构建，工作流会按 `渠道 + build + 架构 + 语言 + 版本` 生成 tag。相同组合下次会自动跳过；如果要强制重新构建，可以在手动运行时启用 `force_build`。

## 可选输入

手动运行时支持以下输入：

- `force_build`：即使已有相同 tag 也重新构建
- `channels`：逗号分隔，默认 `RETAIL,WIF,WIS,CANARY`
- `languages`：逗号分隔，默认 `zh-cn,en-us`
- `arch`：逗号分隔，默认 `amd64,arm64`
- `search_term`：默认 `Windows 11`

`search_term` 用来辅助筛选“最新的 Windows 客户端构建”。如果你后面想改成 Windows 10，可以把它改成 `Windows 10`。

## 产物

每次成功构建后会：

- 上传 ISO 到 Actions artifact
- 上传 ISO 到对应 tag 的 GitHub Release

## 语言说明

由于 UUP dump 的 `Any Language` 不能直接配合专业版 edition 过滤，这个工作流默认把 `zh-cn` 和 `en-us` 作为两个独立构建目标分别生成 ISO，而不是把两个语言合并进同一个镜像。
