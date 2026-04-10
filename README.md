# UUP AutoBuild

This repository provides a GitHub Actions workflow that automatically finds the latest Windows builds on [UUP dump](https://uupdump.net), downloads the official UUP dump conversion package, and runs the bundled `uup_download_windows.cmd` script to generate ISO images.

> [!IMPORTANT]
> Installation images created using the scripts provided by UUP dump are meant only for evaluation purposes.
> The images and their deployments are not supported in any way by Microsoft Corporation.
> The authors are not liable for any damages caused by a misuse of the website.

## Default Behavior

- Channels: `RETAIL`, `WIF`, `WIS`, `CANARY`
- Languages: `zh-cn`, `en-us`
- Edition: `PROFESSIONAL`
- Architectures: `amd64`, `arm64`
- Conversion options:
  - Include updates
  - Run component cleanup
  - Integrate `.NET Framework 3.5`
  - Use solid `ESD` compression

## Workflow

Workflow file: `.github/workflows/uup-autobuild.yml`

Triggers:

- Manual run via `workflow_dispatch`
- Daily scheduled run

To avoid rebuilding the same result repeatedly, the workflow creates a tag based on `channel + build + architecture + language + edition`. If the same tag already exists, that combination is skipped unless `force_build` is enabled.

## Manual Inputs

The workflow supports these inputs when started manually:

- `force_build`: rebuild even if the same tag already exists
- `channels`: comma-separated list, default `RETAIL,WIF,WIS,CANARY`
- `languages`: comma-separated list, default `zh-cn,en-us`
- `arch`: comma-separated list, default `amd64,arm64`
- `search_term`: default `Windows`

`search_term` is used to help filter the latest client build. By default it is not pinned to `Windows 11`, so the workflow tracks the latest Windows client build available for the selected channel. If you want to target a specific generation such as Windows 10, set it to `Windows 10`.

## Build Location

The working directory used during the build is:

- `D:\UUP-Dump\<tag>`

This keeps the download, extraction, and conversion process on the larger `D:` drive.

## Outputs

For each successful build, the workflow:

- uploads the generated ISO to GitHub Actions artifacts
- publishes the ISO to the matching GitHub Release tag

## Language Note

UUP dump's `Any Language` option cannot be cleanly combined with edition filtering for `PROFESSIONAL`, so this workflow builds `zh-cn` and `en-us` as separate ISO outputs rather than merging both languages into a single image.
