# Spine 播放器（HarmonyOS）

基于 **ArkTS / ArkUI + WebView（spine-ts WebGL）** 的 Spine 2D 骨骼动画播放器。支持双模型同屏叠加播放、完整的模型库管理（分组 / 重命名 / 排序 / 回收站）与桌面卡片。

> 本项目为纯鸿蒙（HarmonyOS）原生应用，无任何 Android / iOS 依赖。

## 功能特性

### 播放
- 双模型同屏（模型 1 + 模型 2 叠加显示），槽位独立显隐
- 每模型独立控制：动画切换、皮肤选择、透明度（0–100%）、水平镜像
- 播放速度独立调节（模型 1 / 模型 2，0.25–2x，持久化）
- 动画过渡混合（mix 0–0.5s，切换动画平滑衔接）
- 循环轮播列表：点选多个动画组成播放列表，顺序循环自动推进（双模型独立）
- 播放 / 暂停 / 重置；PMA 直通模式；帧率设置
- 定时随机轮换动画（间隔可配置）
- 播放页屏幕常亮
- 背景颜色设置（内置收藏色板）；截屏保存 PNG

### 模型库
- 导入 ZIP（`.json` / `.skel` + `.atlas` + `.png`），Spine 版本与格式自动识别
- 内容哈希去重，避免重复导入
- 缩略图自动生成（WebView 实时截帧）
- 分组管理：新建 / 重命名 / 解散 / 删除分组（组内模型可选保留或一并处理）
- 模型重命名；库内排序（默认 / 按名称 / 按导入时间，偏好持久化）
- 批量管理模式；搜索（名称 / 分组 / 版本 / 动画）
- 回收站：删除的模型统一进入回收站（单删 / 批量 / 删组），支持恢复、彻底删除、清空；保留策略可配置（永久保留 / 7 天 / 30 天自动清除）

### 桌面卡片
- 桌面卡片展示当前模型快照

### 设置
- 深色主题、槽位透明度、帧率、轮换间隔、屏幕常亮、回收站保留策略等，全部持久化（Preferences）

## 支持的 Spine 版本

| Spine 版本 | 状态 |
| --- | --- |
| 3.8 | ✅ 可播放（JSON 或 SKEL 二进制 + atlas） |
| 4.0 / 4.1 / 4.2 | ✅ 可播放（JSON 或 SKEL 二进制 + atlas） |
| 3.5 – 3.7、4.3 | ⚠️ 可自动识别并标注版本，运行时暂未集成 |

## 技术架构

```
ArkUI（ArkTS，声明式）
├─ Index.ets ─ Tabs：播放 / 模型库 / 设置
│   └─ SpineWebView ── Bridge 协议（JSON 消息）──▶ WebView
│                                                   ├─ player-host.js（宿主适配层）
│                                                   └─ spine-ts WebGL 运行时（3.8 / 4.0 / 4.1 / 4.2）
├─ model/ SpineModelLibrary（导入 / 索引 / 分组 / 回收站，沙箱文件存储）
├─ widget/ EntryFormAbility（桌面卡片快照）
└─ Preferences（设置持久化）
```

- **UI 层**：ArkUI 声明式范式（ArkTS 严格模式），三 Tab 布局
- **渲染层**：WebView 加载本地 `rawfile/web` 资源，调用官方 spine-ts WebGL 运行时渲染，ArkTS 与 JS 间通过自研 Bridge 协议通信（加载模型、播放控制、镜像、透明度、截帧等命令）
- **存储层**：应用沙箱 `files/` 目录存放模型目录与索引（`library.json`、`trash.json`）及缩略图；设置项通过 Preferences 持久化

## 环境要求与构建

- DevEco Studio（含 HarmonyOS SDK，compatibleSdkVersion 26.0.0）
- HarmonyOS 真机或模拟器

```bash
# DevEco Studio 打开工程后 Sync & Build，或命令行：
hvigorw assembleHap
```

> 注意：模拟器不支持 WebGL，无法渲染 Spine 动画（仅可调试 UI 布局），功能验证请使用真机。

> 首次拉取本仓库后，部署真机前请在 DevEco Studio 中配置自动签名（File > Project Structure > Signing Configs，勾选 Automatically generate signature）。仓库不包含任何签名材料。

## 模型导入格式

- 打包为 **ZIP**，内含：
  - 骨架文件：`.json` 或 `.skel`（二进制）
  - 图集文件：`.atlas`
  - 贴图文件：`.png`（可多张）
- 在「模型库 → 导入模型 (ZIP)」中选择文件，导入后自动识别版本并生成缩略图

## 项目结构

```
entry/src/main/ets/
├─ pages/            页面入口（Index.ets）
├─ components/       UI 组件（播放控制条、模型库页、设置页、各类弹窗）
├─ core/             Bridge 协议、Spine 版本检测、偏好管理、主题
├─ model/            模型库（导入、索引、分组、重命名、回收站）
├─ capture/          截帧状态机（CaptureCoordinator）与缩略图生成管线（ThumbPipeline）
├─ widget/           桌面卡片
└─ entryability/     Ability 入口
entry/src/main/resources/rawfile/web/   WebView 渲染层（player-host.js + spine-ts 运行时）
```

## 已知限制

- 模拟器无 WebGL，不能渲染动画，需真机运行
- Spine 3.5 – 3.7 / 4.3 运行时暂未集成（识别但不可播放）
- 仅适配手机（竖屏）


## 开发计划

| 优先级 | 事项 | 说明 |
| --- | --- | --- |
| ✅ P0 | 修复缩略图管线偏好污染 | 已完成（v1.1.0）：管线期间对临时模型跳过槽 0 的 UI 状态更新与偏好持久化 |
| ✅ P1 | 拆分 Index.ets | 已完成（v1.1.0）：抽出截帧状态机 / 缩略图管线 / 桌面卡片 / 回收站协调器，主页面仅保留状态装配与子组件编排 |
| P2 | 集成 Spine 4.3（及 3.5–3.7）运行时 | 补齐 runtimes bundle、播放版本门禁与二进制预读取分支 |
| P3 | 杂项优化 | WebView 资源改 fd 直传降低内存峰值、平板适配评估 |

## 版本记录

### v1.1.1（2026-10-23）

**维护与清理**（行为零变化）
- 删除 8 项死代码：`PrefsManager.flushSync`、`CaptureCoordinator.isRunning`、`ThumbPipeline.startForMissing`、`SpineModelLibrary.deleteModels`、`SpineModelItem.skelPath`、`detectSpineVersion`、`spineVersionDisplayName`、`spineVersionFallbackOrder`
- `Live2DConfig` 精简为实际消费的 `scale` / `idle_motion` / `tap_motions` 字段，移除 `Live2DMotion` 类与未消费字段
- 清理未使用资源：string 14 项、color 16 项（仅保留 `start_window_background`）、删除空 float.json
- 修复 `player-host.js` 文件头回调注释漂移（补 `onScreenTap`）
- 全量核查确认 Bridge 协议 19 命令 / 7 事件双向无孤儿消息

### v1.1.0（2026-10-22）

**新功能**
- 播放速度独立调节（模型 1 / 模型 2，0.25–2x，持久化）
- 动画过渡混合（mix 0–0.5s，切换动画平滑衔接）
- 循环轮播列表：点选动画组成播放列表，顺序循环自动推进（双模型独立，持久化）
- 模型库长列表性能优化：LazyForEach 数据源按 key 差分复用行节点
- 新应用图标

**修复与优化**
- 修复缩略图补全管线「偏好污染」：管线临时加载的模型不再经 `ModelLoaded` / `AnimationChanged` 事件覆盖主模型的动画 / 皮肤 / 轮播偏好
- 修复截帧分块缺失时缩略图管线永久挂起的问题（失败统一走 fail 路由）
- 重构：`Index.ets`（约 2330 行）拆分为 `CaptureCoordinator`（截帧状态机）、`ThumbPipeline`（缩略图管线）、`WidgetCoordinator`（卡片快照）、`TrashCoordinator`（回收站动作）等独立模块（Deps 接口 + 闭包注入），主页面瘦身为状态装配与子组件编排
- 缩略图扫描结果缓存、版本检测复用调用方已读文本，减少重复磁盘 IO
- 注释漂移修正（Spine 版本门禁说明、卡片规格）

### v1.0.0

- 首个完整版本：双模型同屏播放、模型库（导入 / 分组 / 重命名 / 排序 / 回收站）、缩略图自动生成、桌面卡片、Spine 3.8–4.2 运行时支持

## License

- 本项目源码以 [MIT](LICENSE) 许可发布
- 内置的 spine-ts 运行时（`entry/src/main/resources/rawfile/web/runtimes/`）版权归 Esoteric Software 所有，遵循其随附许可证（`LICENSE-spine-*.txt`）；使用与分发需持有对应版本的 Spine 编辑器许可证，详见 Esoteric Software 官方许可条款
- 模型与美术资源版权归各自作者所有，请勿导入或分发未获授权的模型
