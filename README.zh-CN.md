# OpenFly Go for iOS

## 通过 TestFlight 安装

[加入 iOS 测试](https://testflight.apple.com/join/br5vTV92)

请在 iPhone 上打开链接，按页面提示安装 TestFlight 并加入测试，无需先在 GitHub 提交申请。可用名额和设备要求以 TestFlight 页面为准。使用前请阅读下方安全说明，并确认无人机与遥控器兼容。

> [!WARNING]
> **实飞前必读 / Flight safety — read before flying**
>
> 本项目为研究与开发工具，不提供飞行安全保证。**仿真通过不等于实飞安全；自动航线与避障功能不能替代现场检查和飞手监督。**
>
> - **先仿真，再实飞。** 每次实飞前，必须在 App 内置仿真器中完整演练计划航线、拍照、暂停／恢复及任务结束流程。设备不支持仿真或仿真启动失败时，不得直接以实飞代替验证。
> - **条件允许时增加 HIL 验证。** 将真实飞控接入 UE 场景，检查仿真中的状态回传、航向、高度和控制响应。台架测试须先拆桨、固定飞机，并确认 DJI Simulator 已激活；仅显示 HIL 已连接不代表仿真已启动。详见 [HIL 操作指南](docs/HIL_QUICKSTART.md)。
> - **检查高度与信号。** 核对建筑、树木、电线以及转场、返航路径的净空；相对起飞点的航高不等于离地或离楼顶高度。检查定位、遥控和图传信号，并确认失联处置与返航设置适合现场。
> - **启用可用避障，禁止 Sport／S 档。** 消费级无人机并非都具备全向避障；支持避障的机型应启用并确认其生效，核对当前模式下的探测方向与限制。使用机型支持的正常定位飞行模式，不以避障代替安全间距。
> - **实飞前重新预检，全程可接管。** 确认仿真已退出、图像源恢复为真实相机，重新核对起飞点、返航点、航线、电量及天气。飞手须全程监督并随时准备暂停或手动接管，遵守当地飞行规定。
>
> This is a research and development tool, not a flight-safety guarantee. **Passing simulation does not establish real-flight safety.**
>
> - **Simulate before every flight:** rehearse the planned route, capture, pause/resume and completion in the App's built-in simulator. If simulation is unavailable or fails to start, do not substitute a real flight for validation.
> - **Use HIL where supported:** connect the real flight controller to UE to inspect simulated telemetry, heading, altitude and control responses. Remove propellers, secure the aircraft and verify that DJI Simulator is active; an HIL connection alone is not sufficient. See the [HIL guide](docs/HIL_QUICKSTART.md).
> - **Check clearance and signals:** inspect buildings, trees, wires, transit and return paths. Height relative to takeoff is not clearance above terrain or rooftops. Check positioning, control/video links, failsafe behavior and return-to-home settings.
> - **Enable available obstacle avoidance; do not use Sport/S mode.** Not all consumer aircraft have omnidirectional sensing. Verify active sensing directions and limitations, use the supported normal positioning mode and maintain safe clearance.
> - **Recheck before real flight:** exit simulation, restore the real camera and verify takeoff/home positions, route, battery and weather. Maintain pilot supervision and readiness to pause or take over; follow local flight rules.

> 中文快速导航：[版本与机型](#版本选择与机型支持) · [HIL 操作](docs/HIL_QUICKSTART.md) ·
> [工作站连接 / 点云 / 补拍](docs/CLOUD_ROUTE_WORKFLOW.md)。基本航线操作见下文“基本使用”。


OpenFly Go is an open-source mobile ground application for low-cost DJI aircraft. This repository
contains the iOS client based on DJI Mobile SDK V4, including live camera operation, MapKit survey
planning, simulator/HIL integration, resumable execution and reconstruction-oriented capture data.

The current public release intentionally excludes VLN, model inference, model distribution and all
native model runtimes. The corresponding UI is not compiled into the public build.

## 版本选择与机型支持

核对日期：2026-09-21。**V4 / V5 是 DJI SDK 两代产品线，不是同一 App 的“旧版 / 新版”；
不能为了功能更多而给 Mini 2 换装 V5。** 本表适用于三个开源客户端；安装版仍要核对具体构建。

| 客户端 | 当前依赖 | 项目已实机验证的机型 | 地图 | 航线文件 | 云端采集上传 | 已有云端点云 / 航线 |
| --- | --- | --- | --- | --- | --- | --- |
| Android V4 | MSDK 4.16.4 | **DJI Mini 2** | 百度地图 | schema 1–14 | 支持实时触发帧、历史照片上传 | 支持 |
| Android V5 | MSDK 5.18.0 | **DJI Mini 4 Pro** | 百度地图 | schema 1–14 | 支持实时触发帧、历史照片上传 | 支持 |
| iOS | MSDK 4.16.2 | **DJI Mini 2** | MapKit | schema 1–14 | 支持实时触发帧、历史照片上传（需新版构建） | 支持 |

“项目已实机验证”指项目已有硬件使用记录，**不是每次开源打包都重做了所有飞行验收**。
官方 SDK 支持某机型，也不代表本项目已验证该机型的相机、云台、控制权、航线和仿真能力。
相机参数目录里出现一个机型名称，不能作为连接支持的证据。

### DJI 官方支持列表

- [DJI MSDK 官方产品页：Supported Products / Supported Platform](https://developer.dji.com/mobile-sdk/)
- [DJI MSDK V5 官方仓库：Supported Product](https://github.com/dji-sdk/Mobile-SDK-Android-V5#what-is-dji-mobile-sdk-v5)
- [DJI MSDK V4 官方产品支持表](https://developer.dji.com/mobile-sdk/documentation/introduction/product_introduction.html#supported-products)
- [Android V4 4.16.4 官方版本](https://github.com/dji-sdk/Mobile-SDK-Android/tree/V4.16.4)
- [iOS V4 4.16.2 官方版本](https://github.com/dji-sdk/Mobile-SDK-iOS/tree/v4.16.2)

官方网页会更新，V4 旧产品介绍页也可能没有列全后来新增的机型；应同时核对**本客户端锁定的
SDK 版本、Android/iOS 平台、飞机固件和遥控器**，不要只看网页上的最新 SDK。

| 机型 / 产品线 | 如何选择 | 本项目承诺范围 |
| --- | --- | --- |
| Mini 2 | Android V4 或 iOS | 项目已实机验证；仍需按当前固件做预检 |
| Mini 4 Pro | Android V5 | 项目已实机验证；本项目 iOS 不支持 |
| Mini 3 / Mini 3 Pro | DJI 官方列在 V5；选 Android V5 做兼容验收 | 尚未按本项目完整流程实机验收 |
| Mavic 3 Enterprise、Mavic 3TA、Matrice 30 / 300 RTK / 350 RTK / 400、Matrice 4 / 4D Enterprise 系列 | 查 V5 官方清单和固件要求 | 不承诺企业负载、多相机和全部航线功能已适配；Mavic 3 Enterprise 不等于消费版 Mavic 3 |
| Mavic Pro / Mavic Air、Mavic 2 Pro / Zoom / Enterprise、Spark、Phantom、Inspire、较早 Matrice 产品 | 查 V4 表中的**具体型号**和平台限制，不能按整个系列推断 | 仅 SDK 候选机型，本项目未逐一验收 |
| Mavic Mini、Mini SE、Mavic Air 2、Air 2S 等其他 V4 产品 | 查对应 Android/iOS SDK 版本说明，不能由 Android 支持推断 iOS 支持 | 当前不列为本项目已验收机型 |
| Avata / Avata 2、Neo / Neo 2 等未适配产品 | **不属于本项目支持范围** | 不提供破解接入；刷 App、切换 V4/V5 或有图传都不等于可控 |

优先使用能通过 USB 数据线连接手机、且被对应 SDK 支持的遥控器。开源 V5 **不包含 RC2
破解 / 视频兼容实验**；不要把遥控器能装 APK 等同于可运行本项目。SDK 列表中的云台 / 负载
（例如 H30）也不是独立的飞机型号。

### 功能与构建差异

- 三端都有区域航线规划、预览、预检、暂停 / 恢复及 HIL 客户端；具体硬件 API 受机型限制。
- Android V5 有 DJI WPMZ/KMZ 执行路径；V4 / iOS 的 Mini 2 航线使用 App 侧控制，
  **不要当作上传后可以关掉 App 的离线机载任务**。保持连接和前台运行。
- 默认补拍是**到点稳定后拍照**（schema 13）。Android V4 / V5 / iOS 都支持 schema 14
  “连续补拍（实验）”：V4 / iOS 使用 App 侧 Virtual Stick，V5 使用 DJI KMZ；仅符合条件的
  中间拍照点连续通过，边界和转弯仍可停拍。默认仍使用 schema 13 停点拍照。
  V4 / iOS 需要 2026-09-22 或之后包含此适配的构建；并非仅放宽版本号，也不代表新增实飞验收。
  详见 [iOS schema 14 连续补拍与验证范围](docs/SCHEMA14_CONTINUOUS_RECAPTURE_2026-09-22.md)。
- 开源版不含 MNN / VLN / 模型下载及私有推理运行时；云端航线与点云功能不依赖这些模块。
- Android 保留实验仿地但默认关闭；iOS Release 未启用仿地，拒绝带 `terrainPlan` 的任务。
- Debug 供开发，Release 是构建配置而不是“全部机型已验收”。自行编译需自己的 Key / 签名；
  安装版由维护者在私有环境签名，功能以该包说明为准。签名不同不能直接覆盖，勿为换包盲目清数据。

## Features

- DJI connection, account state, telemetry, camera, gimbal and flight status;
- live camera preview and photo/video operations;
- MapKit survey editing, route preview, capture scheduling and time estimation;
- resumable execution, manual-takeover detection and DJI return-to-home handoff;
- UE/AirSim HIL transport and DJI Simulator validation;
- capture metadata for reconstruction workflows;
- remote V86 point-cloud viewing and cloud mission download/import, without model inference;
- experimental terrain/DSM planning retained behind a build flag and off by default.

## 基本使用：连接 → 航线 → 云端结果 → 补拍

1. **首次连接**：iPhone 用数据线连接受支持遥控器，完成必要权限；确认 SDK 注册成功、
   飞机与相机型号正确、遥测和图传更新。自行编译需要匹配 Bundle ID 的 DJI Key 和有效签名。
2. **规划航线**：从地图打开“区域航线”，在“区域”里按顺序点至少三个边界点并拖动调整。
   核对相机 / 镜头 / 照片比例，选择正射或倾斜视角；在“飞行 / 影像”里设置高度或 GSD、
   速度、重叠率、云台角度、起点及完成动作。保存到任务库，检查全线、照片数和预计时间。
3. **预检与执行**：明确高度基准；任务保存 WGS84，不手工叠加底图偏移。先做小范围预览和
   安全预检，处理 GPS、Home、相机、控制权等阻断项；通过后才由飞手显式执行。
   任务导入不会自动起飞。Mini 2 使用 App 侧执行，不能关 App 等待机载离线跑完。
4. **先仿真后实飞**：按 [HIL 指南](docs/HIL_QUICKSTART.md) 连接 UE；Xcode 的 Mock 模拟器
   不是 DJI 飞控仿真。暂停或人工介入后检查原因，再显式恢复；运行 / 暂停任务不能被导入覆盖。
5. **读取云端**：在区域航线标题旁点云朵，或“更多 → 云端点云与航线”。输入工作站根地址、
   Bearer 访问码和**已有会话 ID**，依次“连接并读取结果 → 下载并查看点云 → 下载云端航线”。
6. **执行补拍**：先核对下载摘要，再“导入任务库并在地图预览”；检查 ASL / 起飞基准、路径、
   相机和任务审核信息，完成本地预检后执行。`safe_to_execute` 非 true 的预览警告不是飞行授权。
   iOS 接受 schema 1–14；连续补拍需明确选择实验模式，不能只改版本号；Release 仍拒绝仿地任务。

**iOS 已接入创建会话、航线触发图传帧 / 历史照片上传、显式提交重建和失败重试。**
在同一云端页面展开上传区；原始照片需自带 GPS / ASL，实时帧不是机载 SD 原片。
队列落盘，重启后手动继续；上传完成不自动提交、不自动执行航线。
详见 [图片上传指南](docs/CLOUD_UPLOAD.md)。旧安装包需更新才有这些入口。
详见 [云端结果与补拍指南](docs/CLOUD_ROUTE_WORKFLOW.md)。工作站部署由项目总入口仓库的
工作站文档说明，本仓库不重复服务安装；总入口地址尚未配置，按发布说明获取，不使用本机路径替代公开链接。

## Requirements

- macOS with Xcode 26 or a compatible newer release;
- XcodeGen and CocoaPods;
- an Apple Developer team for device signing;
- a DJI Developer account and an iOS MSDK V4 App Key for your Bundle Identifier.

## Configuration

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

Configure your own values in the ignored local file:

```xcconfig
OPENFLY_BUNDLE_ID = com.example.openflygo
DJI_SDK_APP_KEY = your_dji_app_key
DEVELOPMENT_TEAM = YOUR_APPLE_TEAM_ID
```

Never commit a production DJI key, Apple certificate private key, `.p12` file or provisioning
material. Official builds inject maintainer credentials in a private signing environment.

## Build and test

The simulator build uses the mock flight provider. Integrate Pods after generating the project
so that both simulator and device builds retain the correct dependency configuration:

```bash
xcodegen generate
pod install --no-repo-update
xcodebuild -workspace DJIVLNiOS.xcworkspace -scheme DJIVLNiOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

For a device build, restore CocoaPods and use the workspace:

```bash
xcodegen generate
pod install
xcodebuild -workspace DJIVLNiOS.xcworkspace -scheme DJIVLNiOS \
  -destination 'generic/platform=iOS' build
```

## Feature gates

Terrain planning remains in the source but is **off by default**. The public Release configuration
does not define `OPENFLY_ENABLE_TERRAIN`; importing a mission that requires terrain following fails
closed. In development builds, exposing the terrain UI still leaves its user toggle off initially.

VLN/model-inference feature flags and implementations are not part of this public snapshot.

## Architecture

```text
DJI iOS MSDK V4 ── telemetry / camera / gimbal / control
          │
          ├── SwiftUI flight HUD and MapKit
          ├── survey planner and execution policies
          ├── DJI Simulator / UE HIL bridge
          └── reconstruction-oriented capture metadata
```

## Safety

This is research software, not a replacement for the remote pilot, DJI flight-safety systems,
airspace authorization, site inspection or legal compliance. Keep visual line of sight, maintain a
manual takeover path and validate changes in simulation before any real flight. Unsupported or stale
telemetry must fail closed.

Useful documentation:

- [Cloud point clouds and routes](docs/CLOUD_ROUTE_WORKFLOW.md)
- [Simulator validation](docs/SIMULATOR_VALIDATION.md)
- [Real-device checklist](docs/REAL_DEVICE_CHECKLIST.md)
- [Release feature gates](docs/RELEASE_FEATURE_FLAGS.md)

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md) and [SECURITY.md](SECURITY.md) before submitting flight-control
changes. OpenFly Go is licensed under the [Apache License 2.0](LICENSE). Third-party components retain
their own terms; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## 相机参数匹配

换机、切镜头或改拍照模式前，请阅读 [航线相机参数匹配与限制](docs/CAMERA_PROFILE_COMPATIBILITY.md)。
官方支持连接不等于本项目已验证该相机；未确认的参数不能用于授权航线执行。

## License and third-party software

Original OpenFly Go code uses [Apache-2.0](LICENSE). DJI SDK binaries, map
services and other dependencies retain their own terms. See
[third-party notices](THIRD_PARTY_NOTICES.md) and the retained files in `LICENSES/`;
include the applicable notices when distributing an installation package.
