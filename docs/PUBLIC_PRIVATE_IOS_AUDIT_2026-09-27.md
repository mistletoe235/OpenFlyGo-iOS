# iOS 公开/私有航线实现复核

日期：2026-09-27。公开基线 `099dc1a`，私有基线 `dfc2ee3`；比较的是工作区，包含未提交修复。

## 确认的遗漏与修复

- 私有 `dfc2ee3` 的相机方向修复只同步了部分链路：公开 provider 有数据，但缺少方向解析及图像元数据输出。
  补齐 `FlightModels` 的机体/云台方向解析、`EventLog` 的 JPEG 方向/EXIF 姿态说明、
  HIL sidecar/上传 JSON 的相机姿态字段和对应测试。避免把飞机机头方向直接当作所有照片的相机方向。
- 两份实现共同存在保存队列的内存风险：拍照后图传计数在异步文件保存完成之前就减少，
  慢速磁盘可持续积压编码帧。现在运行层等待保存 completion，预算覆盖取帧和异步写入全过程。
- `SessionCaptureStore` 还在入队之前独立限制最多 2 个航线图像写入，直到主队列 completion 返回才释放。
  预算满时立即返回繁忙，不把更多大图排进等待队列；失败和重复释放有回归覆盖。
  只影响可选手机副本，不更改 DJI 拍照成功与否。共享修复也应用到私有 iOS。

## 检查后没有机械移植的部分

- 地图已有静态航线相等判断、标记复用、可更新执行覆盖物及 renderer 刷新，公开/私有实现一致。
  没有证据表明 iOS 存在 V5 的同一种覆盖物高频重建问题。
- DJI 控制回调已经在 MainActor 内检查代次；取消重试任务及计时器清理已有实现。
  不机械添加 Android 的另一套控制权状态机。
- 保留此前前台常亮、后台释放控制的行为及测试。
- 保留公开版的模型剔除、可配置云端服务、Release 仿地关闭、默认不保存手机副本。
  不覆盖成私有旧端点/模型实现，也不把私有测试素材路径带入公开仓库。

## 可重复检查

```sh
python3 scripts/check_private_ios_parity.py --private-root /path/to/private-ios
```

按原文比较共用 Survey/Providers/HIL、核心姿态/图像保存/控制及地图文件；40 项通过。
不计算哈希，不自动复制。模型排除、云端地址、构建特性、FlightViewModel 及剩余 UI/测试明确保留人工评审。
注入一处 EventLog 差异的内存负例正确失败，未修改真实文件。

## 验证与交付

- 公开 Simulator 全量：205 项，203 通过、2 项既有跳过、0 失败。
- 私有 Simulator 定向：PhoneCaptureRetentionTests、SurveyLatestParityTests、SurveyRuntimeTests 共 84 项通过。
- 图像预算回归含 10 万次申请、真实 SessionCaptureStore 暂停写入队列、1000 次拒绝、恢复及写入错误释放。
  这些是可控软件测试，不是真机 DJI 解码/拍照/图传并行长时验证。
- 设备 Release 构建 `1.0 (20260927.2)` 通过。直装包使用既有安装版 bundle ID/SDK key 和 Apple Development 签名，
  本地密钥配置被 Git 忽略；已验证签名、bundle ID、版本与无 MNN/模型资产。
- 此包是 Release 优化的开发签名直装包，不是 App Store Connect 分发包，本轮没有上传 Connect。
- iPhone 仍存在旧 App 进程。最新读取的日志止于较早的后台释放/断开状态，不能单凭旧日志断言当前控制安全；
  未强杀或覆盖，待用户退出旧 App 后安装。不要将“构建成功”写成“已安装”。

本轮没有执行真机起飞/航线或修改飞机设置，没有提交/推送 Git。
