# Cloud point clouds and routes

## 中文操作：连接工作站并执行已有补拍航线

**工作站部署由项目总入口仓库统一说明**；本文只说明 App 端连接，不提供服务器安装命令。
部署者需要给出手机可达的 HTTP/HTTPS 根地址、Bearer 访问码、已有会话 ID，以及兼容 iOS 的
schema 1–14 航线。也可在本页上传区创建会话、上传航线触发图传帧 / 历史照片，再显式提交
重建，详见 [图片上传指南](CLOUD_UPLOAD.md)。保存照片不代表已上传，上传不代表已提交。

1. 打开“区域航线”，点标题旁云朵，或“更多 → 云端点云与航线”。
2. 填服务根地址，例如 `https://reconstruction.example.com`，替换为真实可达地址；不要填
   SSH 地址、`/api/sessions/...` 或 `127.0.0.1`（在 iPhone 上表示 iPhone 自己）。
3. 访问码只填 token 本身，App 添加 Bearer 前缀；填目标服务器上的已有会话 ID，而非任务名。
   使用 HTTPS；开源 iOS 没有私有生产 HTTP 地址白名单，公网 HTTP 可能被 ATS 拦截，
   不以全局关闭 ATS / 证书校验处理。地址变化后使用对应的访问码。
4. 点“连接并读取结果 / 刷新云端结果”，查看会话阶段和错误；点“下载并查看点云”，用手势
   旋转缩放。读取的是已生成的 PLY，不是 SSH 桌面，不是直播视频，也不是实时避障地图。
5. 点“下载云端航线”，核对摘要，再“导入任务库并在地图预览”。导入不申请控制权、不上传飞机、
   不自动起飞或执行。运行 / 暂停任务锁存在时不能用新任务覆盖，下载结束仍会重查锁。
6. **实飞前**检查起飞点与相对高度 / ASL 基准、WGS84、相机、补拍组、拍照点、往返路径和
   电池预算；先用 HIL / 小任务验证，完成本地预检后才显式执行。Mini 2 执行保持 App 前台。
7. `safe_to_execute` 缺失或 false 会显示警告；iOS 允许下载导入预览不等于允许实飞，也不等于
   Android 的导入策略。不得篡改审核字段。`test_only` / `relative_height_test` 禁止下载为航线。
8. schema 14 连续补拍通过 iOS 的 App 侧 Virtual Stick 执行，不使用 V5 KMZ。新建上传
   会话可显式勾选“连续补拍（实验）”，默认仍停车拍照；不手改 schema，保持 App 前台和连接。
   具体条件与验收范围见 [iOS schema 14 说明](SCHEMA14_CONTINUOUS_RECAPTURE_2026-09-22.md)。
   iOS Release 不启用仿地，带 `terrainPlan` 的任务也会被拒绝。
9. 执行后核对实际照片和任务记录；新一轮采集可在上传区另建会话。等待上传成功后显式
   提交重建，再手动刷新结果；不会自动循环执行补拍。

| 现象 | 优先检查 |
| --- | --- |
| 连接超时 / ATS 错误 | 手机路由、VPN、真实服务地址、HTTPS 和证书；本地网络权限 |
| HTTP 401 / 403 | token / 会话权限；不在截图和日志暴露访问码 |
| 404 / session ID 不匹配 | 服务地址和 ID 是否属于同一个服务器，根地址是否多了 API 路径 |
| 下载按钮不可用 | 服务是否已经生成产物，是否为测试会话；不是“SSH 未连接” |
| PLY 不显示 | 文件限制 / 格式 / 同源 URL；下文列出支持格式与 32 MiB 上限 |
| 导入被拒 / 执行灰色 | schema、仿地开关、任务锁、审核和本地飞行预检；不能靠修改保护条件解决 |

渐进预览是否可用取决于工作站；浏览区按手动读取 / 刷新结果工作，没有服务端会话列表入口。


This route-related functionality is part of the public app. It does not depend on MNN, VLN,
model inference, model downloads, or the private inference repository.

## Use

Open the survey planner, then tap the cloud icon (also available in More actions). Enter your
HTTP/HTTPS service root URL, bearer access code and an **existing** session ID. This is a V86
reconstruction service connection, not SSH. The public app leaves the endpoint blank by default.

1. Connect/refresh calls `GET /api/sessions/{id}/result` and verifies the returned session ID.
2. Download/view opens `point_cloud.url` as a rotatable, zoomable PLY point cloud.
3. Download mission reads `openfly_v5_mission.url`, validates it and shows a summary.
4. Import saves it to the local mission library and displays it on the map. It does not execute,
   request flight control, or take off. Confirm coordinates/altitude and complete normal preflight.

The browser does not upload images, create sessions, start reconstruction, retry processing or
cancel a server task. The separate [upload section](CLOUD_UPLOAD.md) can create an iOS session,
queue survey-trigger downlink frames or geotagged originals, and explicitly finalize reconstruction.
There is no session-list/SSH interface and no candidate camera overlay in the iOS viewer yet.

## Boundaries

- Mission schema 1–14, WGS84 only. Schema 14 requires an explicit known recapture mode; continuous
  missions use bounded app-side Virtual Stick guidance, not KMZ. The cloud checkbox defaults off.
  Active recapture uses the existing contract validator. Release builds reject
  terrain-following missions when that feature is disabled.
- `test_only=true` or `contract.altitude_mode=relative_height_test` cannot be downloaded as a mission.
- A missing/false `safe_to_execute` is explicitly warned about. Import for review is not a safety
  certification and does not skip local execution checks.
- An executing/paused mission cannot be replaced; the import callback checks the live lock again.
- JSON/result limit 1 MiB, mission limit 8 MiB, PLY limit 32 MiB. The viewer supports ASCII and
  binary-little-endian XYZ PLY, at most 5 million source vertices and 50,000 displayed samples.
- This is an existing reconstruction result, **not** a live obstacle map.

## Credentials and transport

Use HTTPS for public services. The public app does not globally disable ATS or include an exception
for the private production server. Local networking remains enabled. HTTP can expose the bearer
token on the network; do not disable certificate validation to work around server configuration.

Access codes are stored in the device Keychain, isolated by service origin. Only same-origin asset
links are accepted and HTTP redirects are rejected. Credentials are not written into mission files
or logs. Editing connection settings or closing the panel cancels the previous request.

## Build

Run `xcodegen generate`, then `pod install --no-repo-update`, then build/test the workspace. The
app/test Debug/Release xcconfig files include the appropriate CocoaPods configuration and retain
the public `OpenFlyGo.xcconfig` / ignored `Local.xcconfig` overrides. Do not replace the public
project configuration with the private MNN-enabled one.

The latest capture-policy sync also requires `FlightTelemetry.gimbalStateTimestamp` and the real
DJI gimbal callback timestamp. These dependencies are included; a missing/stale timestamp still
fails the capture-pose gate rather than faking freshness.

Protocol tests use controlled responses, not a production login. A valid service credential and
session are still required for an end-to-end check against your reconstruction server.
