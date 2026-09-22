# iOS schema 14 连续补拍

更新日期：2026-09-22。私有版与开源版均已适配；App 版本 1.0 / build 20260922。

## 使用方式与兼容性

1. 在云端页面创建上传会话时，按需勾选“连续补拍（实验）”；默认关闭。
2. 手机声明支持 `[13,14]`。关闭时请求 `STOP_AND_CAPTURE`；开启时请求
   `CONTINUOUS_EXPERIMENTAL`。已有会话不会被追溯修改，服务端须按能力协商导出。
3. 下载航线后仍需预览、核对相机和高度基准、完成预检并明确启动。
   下载、选择模式、恢复任务库都不会自行起飞。
4. iOS 接受 WGS84 schema 1–14；连续模式必须有 `active_mapping`。
   schema 14 必须提供已知的 `recapture_flight_mode`；未知值、缺字段、
   在旧版本中强塞模式字段、schema 15 等均拒绝，不通过改版本号降级。
5. 普通和停止拍照任务继续导出 schema 13；旧任务库、断点任务与旧上传队列仍可读取。
   Codable 旧数据缺少新模式字段时按停止拍照恢复。
6. 保留主动补拍验证、云端预览 / 审核提示、相对高度测试限制及 Release 仿地禁用，
   不因支持新 schema 绕过原有执行检查。

## 执行逻辑

iOS 使用已有 MSDK V4 的 App 侧 Virtual Stick 执行，不是 V5 KMZ，也不是离线机载航线。
必须保持 App 前台、遥控连接和控制权。控制循环沿用现有 40 ms 调度，
调度周期不代表 DJI 新鲜遥测频率或实际硬件控制精度。

连续通过仅用于满足以下条件的中间拍照点：

- 前、中、后三点均为点拍，拍照视角一致；主动补拍仍须通过现有任务验证器。
- 有 pass 元数据时，三点同属一个区域，拍摄角色均为 `SURVEY`，且不是重建桥接点。
  `pass_index` 是逐点编号，不用编号相等判定同一连续段。
- 两侧水平段各至少 3 m、转角不超过 30°；相邻航向差不超过 5°、
  云台俯仰差不超过 3°、高度差不超过 0.5 m。
- 首尾、转场、恢复转场及不满足条件的点仍使用原有停点逻辑。

连续段采用有界前视速度跟随，并按相机最小拍照间隔和段长限速。
触发拍照仍需进入水平 1.2 m 的窗口；航向误差不超过 3°、高度误差不超过 0.4 m，
云台已通过原有稳定检查，飞控 / 云台遥测均不超过 1 s 且不是未来时间。
连续模式不要求水平速度降到零，但不放宽这些姿态与连接要求。

等待拍照回调时继续跟随，前视目标最多到下一段中点；慢相机仍可能导致减速 / 停下。
收到成功回调才推进任务点，不提前计完成。拍照失败、8 s 无回调、错过窗口或
等待时姿态失效会暂停。人工接管后的过期回调不能恢复运动或推进任务。

## 验证边界

新增测试覆盖 schema 14 往返和云端验证、错误输入、旧 Codable 数据、默认 / 显式能力声明、
几何 / 区域限制和遥测新鲜度。数值跟随覆盖 64 组间距 × 速度 × 拍照延迟；
执行状态机覆盖等待回调继续运动、成功才推进、失败暂停、人工接管后忽略回调及错过窗口。
这些使用 XCTest、简化运动学和假飞控提供器，不是 DJI 模拟器或实飞验收。

拍照命令成功不等于精确曝光时间，也不等于已核对 SD 卡原片；移动模糊、曝光位置、
真实相机节拍及飞行跟随精度仍需硬件验收。本次未连接或控制飞机，也未安装手机或上传 Connect。

## 本次构建与回归结果

| 工程 | Xcode Simulator 全量 Debug 测试 | arm64 真机 Release 编译 |
| --- | --- | --- |
| 私有 iOS | 265 通过，0 失败 | 成功，build 20260922 |
| 开源 iOS | 189 通过，2 跳过，0 失败 | 成功，build 20260922 |

新增 11 项针对性测试全部通过，包含 64 组数值跟随和 4 项异步执行测试。
开源版跳过项为需显式配置的在线服务测试、仓库未携带的 Android DSM 测试夹具。
没有为了通过测试放宽飞行、相机或任务验证条件。

复现命令（在对应 iOS 工程根目录）：

```sh
xcodegen generate
pod install --no-repo-update
xcodebuild -workspace DJIVLNiOS.xcworkspace -scheme DJIVLNiOS \
  -destination 'platform=iOS Simulator,id=F79457A2-9EAF-4585-850A-8B30BAFC8013' \
  -derivedDataPath build test
xcodebuild -workspace DJIVLNiOS.xcworkspace -scheme DJIVLNiOS \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build-release CODE_SIGNING_ALLOWED=NO build
```

Simulator ID 应替换为本机已有设备。本次 Release 使用 `CODE_SIGNING_ALLOWED=NO` 验证
真机架构编译，不是已签名的可分发 IPA，也未进行 App Store Connect 上传。
