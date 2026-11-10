# Karakeep 书签插件

开发流程见[插件开发指南](https://github.com/geraldpeng6/wonton-docs/blob/main/develop.md)。

这个仓库是 [Karakeep](https://karakeep.com) 插件：收藏链接、笔记和图片，自动抓取标题、正文和整页截图，
AI 自动打标签，全文搜索。登录交给云吞的身份提供方（`sso: oidc`，上游 Better Auth 的 OIDC），
打开网页自动跳转登录，没有第二个登录页；AI 打标经云吞的模型网关（`models` 权限）完成，
不接任何外部 AI 服务。

## 组件

按上游官方 compose 的三件套，全部用上游官方镜像并按多架构摘要固定：

| 服务 | 镜像 | 用途 |
| --- | --- | --- |
| `web` | `ghcr.io/karakeep-app/karakeep:0.34.1` | 应用本体（网页、抓取、AI 推理、搜索索引都在这一个 AIO 容器里） |
| `chrome` | `ghcr.io/karakeep-app/karakeep-chrome:release` | 无头浏览器，抓网页、整页截图（amd64 是 Google Chrome，arm64 是 Debian Chromium） |
| `meilisearch` | `getmeili/meilisearch:v1.55.0` | 全文搜索 |

出网权限（`network.egress`）用于抓取收藏的网页内容；镜像升级 Meilisearch 大版本时需按上游的
[升级指南](https://docs.karakeep.com/administration/meilisearch-upgrade/)迁移索引，插件先固定在 v1.55。

## 核心升级

核心升级时容器会按新的签发方自动重建，不用重装；账号按已有的身份记录认回原账号，数据不动。 升级后若页面报「插件记录已损坏」，是核心读不了旧格式的 model-keys 记录（缺 `bot_keys` 字段），重装也修不好，要等核心修复或手补字段。

## 数据

- 书签、数据库和抓取的资产在插件数据目录的 `data/` 子目录里。
- Meilisearch 索引在插件自己的命名卷 `meilisearch` 里。
- AI 打标的模型和密钥由云吞的模型网关注入，用户在网关里换模型即可，插件不用改。

## 首次使用

装好后打开网页，经云吞登录后第一次会自动建好账号（第一个登录的是管理员）。浏览器扩展和手机 App
可在 Karakeep 设置里生成 API key 后接入。

## 图标

`icon.png` 使用 Karakeep 官方标志，来源、处理方式和商标说明见 [NOTICE](NOTICE)。
