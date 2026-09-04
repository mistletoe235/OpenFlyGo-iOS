'use client';

import { Check, ChevronRight, MapPin, ShieldCheck } from 'lucide-react';
import { useLocale } from '@/components/locale';
import { SiteFooter, SiteHeader } from '@/components/site-chrome';

type Section = { id: string; title: string; body?: string[]; bullets?: string[] };

const copy: Record<'zh' | 'en', {
  label: string; title: string; summary: string; effective: string; updated: string;
  highlights: string[]; contents: string; tip: string; sections: Section[];
}> = {
  zh: {
    label: '隐私政策',
    title: '你的飞行数据，默认留在你的设备与网络中。',
    summary: '本政策说明 OpenFly Go iOS 如何访问、处理和保存定位、飞行遥测、图传、航线及仿真数据。我们不出售个人信息，也不使用广告或跨应用跟踪。',
    effective: '生效日期：2026 年 8 月 29 日', updated: '最后更新：2026 年 9 月 1 日',
    highlights: ['无广告与跨应用跟踪', '飞行记录默认本地保存', '局域网 HIL 由用户主动连接'],
    contents: '目录', tip: '你可以在 iOS“设置”中查看并修改 OpenFly Go 的定位、本地网络和其他权限。',
    sections: [
      { id: 'scope', title: '1. 适用范围', body: ['本政策适用于 OpenFly Go iOS 应用及其配套的本地功能。OpenFly Go 首版是面向无人机航线规划、采集和硬件在环仿真的工具。', '本政策不替代 Apple、DJI 或用户自行配置服务的隐私政策。使用这些第三方服务时，其各自条款也可能适用。'] },
      { id: 'data', title: '2. 我们处理的数据', body: ['为提供你主动使用的功能，应用可能在设备上处理以下数据：'], bullets: ['定位与方向：手机或遥控器位置、经纬度、精度、航向和返航点参考。', '飞行与设备状态：飞行器位置、高度、速度、姿态、云台、相机、电池、遥控器和连接状态。', '图像与任务记录：实时图传帧、拍摄时间、航线、规划区域、任务参数和运行日志。保存的图像或记录可能包含时间、坐标、高度、姿态及相机信息。', '仿真数据：用户主动连接 UE/AirSim 等 HIL 环境时交换的虚拟相机、状态和控制数据。', '本地设置与文件：语言选择、航线任务、仿真地址以及用户导入或导出的文件。'] },
      { id: 'use', title: '3. 数据用途', bullets: ['在地图和飞行主界面显示当前位置、航迹、状态和安全信息。', '生成、预览、执行、暂停和恢复用户创建的航线任务。', '控制兼容 DJI 相机，并将用户要求的任务记录保存在本机。', '与用户指定的局域网仿真器联调并预览虚拟相机。', '诊断设备连接和运行错误。'] },
      { id: 'permissions', title: '4. 系统权限', body: ['OpenFly Go 只应在相关功能需要时请求权限。你可以随时在 iOS“设置”中更改授权。'], bullets: ['使用 App 时定位：显示设备/遥控器位置、辅助返航点和任务记录。', '本地网络：通过同一 Wi‑Fi 或手机热点连接用户指定的 UE/AirSim HIL 环境。', '蓝牙：仅在兼容 DJI 设备或其 SDK 的连接流程确有需要时使用。', '文件访问：由你主动导入、导出航线、日志或任务资料。'] },
      { id: 'storage', title: '5. 飞行日志、本地保存与删除', body: ['OpenFly Go 开发者不接收你的飞行日志。飞行日志、航线、设置、缓存和你选择保存的图像默认仅保存在你的 iPhone 中；只有在你主动导出、分享或发送相关文件时，这些文件才会离开设备。', '本机数据会保留到你在应用或“文件”中删除、应用自动清理、清除应用数据或卸载应用为止。删除应用通常会移除其沙盒内的数据，但已由你导出或分享到其他位置的文件需要你另行删除。', 'DJI Mobile SDK 可能独立生成 SDK 日志、处理模糊位置或 Analytics Data。这些由 DJI SDK 执行的第三方处理适用 DJI 隐私政策，并在下一节单独说明；OpenFly Go 不会把 DJI SDK 的本地飞行记录自动上传到 OpenFly 自建服务器。'] },
      { id: 'network', title: '6. 网络请求与第三方服务', body: ['应用不会把飞行记录自动上传到 OpenFly Go 自建云端，但使用 DJI 功能或用户指定的网络功能会产生以下请求：'], bullets: ['DJI SDK Analytics：SDK 4.16.2 包含注册、连接、飞行、任务和 Virtual Stick 等事件的收集、缓存与网络上报代码。OpenFly 不主动授权 DJI 获取飞机或遥控器硬件序列号；DJI 接口说明该权限默认关闭，但在中国大陆仍可能因政策原因发送序列号。', 'DJI 模糊位置：DJI 接口说明，手机或 DJI 产品位置会先随机偏移 5–10 km，再用于更新附近禁飞区；该模糊位置访问默认启用且不能关闭。OpenFly 不把它描述为精确位置。', 'DJI Warranty Logs：SDK 还可能在本机保存函数调用、协议/命令、时间和结果等保修日志；按照 DJI 条款，这些日志不会在没有用户事先同意的情况下自动传给 DJI。', 'DJI 的第三方处理适用其隐私政策：https://www.dji.com/policy', '用户指定的 HIL：当你填写或发现 UE/AirSim 地址并启动 HIL 时，应用会向该局域网设备发送你主动请求的状态、控制和虚拟相机数据。', 'Apple 与 App Store：下载、更新、崩溃诊断及系统权限由 Apple 按其政策处理。'] },
      { id: 'sharing', title: '7. 共享、出售与跟踪', body: ['我们不出售或出租个人信息，不展示个性化广告，也不使用数据在其他公司的应用或网站之间跟踪你。', 'OpenFly Go 不自动上传飞行日志。只有你主动使用导出、系统分享、支持邮件或局域网仿真功能时，你选择的数据才会发送到对应位置或设备。', 'DJI SDK 的注册、模糊位置、Analytics Data 和 Warranty Logs 按 DJI 自身政策及授权机制处理；这与 OpenFly Go 接收飞行日志不同。法律要求、保护用户安全或维护合法权益时除外。'] },
      { id: 'security', title: '8. 安全与飞行提示', body: ['我们采用系统沙盒和受限的局域网连接等措施减少未授权访问风险，但任何存储或传输方式都无法保证绝对安全。请不要在日志、任务名称或自定义地址中填写不必要的敏感信息。', 'OpenFly Go 是工程工具，不替代飞手判断、现场观察、障碍物规避、返航设置或当地法规。任何航线都必须由操作者在飞行前核验。'] },
      { id: 'children', title: '9. 未成年人', body: ['OpenFly Go 面向具备相应能力的无人机操作者和研发人员，不以儿童为目标用户。若监护人发现未成年人向我们提供了个人信息，请通过下方方式联系我们。'] },
      { id: 'changes', title: '10. 政策更新与联系', body: ['我们可能因功能、法律或第三方服务变化更新本政策，并在本页标注新的“最后更新”日期。重大变化会在合理范围内通过应用或产品页面提示。', '如有隐私问题、数据请求或投诉，请发送邮件至 you_zhongrui@outlook.com。为保护你的信息，请不要在邮件中附带不必要的账号凭据、精确位置或完整飞行日志。'] },
    ],
  },
  en: {
    label: 'Privacy Policy', title: 'Your flight data stays on your device and network by default.',
    summary: 'This policy explains how OpenFly Go for iOS accesses, processes, and stores location, flight telemetry, video, mission, and simulation data. We do not sell personal information or use advertising or cross-app tracking.',
    effective: 'Effective: August 29, 2026', updated: 'Last updated: September 1, 2026',
    highlights: ['No ads or cross-app tracking', 'Flight records stored locally by default', 'User-initiated local HIL connections'],
    contents: 'On this page', tip: 'You can review and change OpenFly Go’s location, local-network, and other permissions in iOS Settings.',
    sections: [
      { id: 'scope', title: '1. Scope', body: ['This policy applies to the OpenFly Go iOS application and its companion local features. The first release is a tool for drone mission planning, data capture, and hardware-in-the-loop simulation.', 'This policy does not replace the privacy policies of Apple, DJI, or services configured by you. Their terms may also apply when you use those services.'] },
      { id: 'data', title: '2. Data We Process', body: ['To provide features you choose to use, the app may process the following data on your device:'], bullets: ['Location and heading: phone or controller location, coordinates, accuracy, heading, and home-point references.', 'Flight and device state: aircraft position, altitude, velocity, attitude, gimbal, camera, battery, remote controller, and connection status.', 'Images and mission records: live video frames, capture time, routes, planning areas, mission parameters, and operational logs. Saved images or records may include time, coordinates, altitude, attitude, and camera information.', 'Simulation data: virtual camera, state, and control data exchanged when you connect to a UE/AirSim or other HIL environment.', 'Local settings and files: language, missions, simulation addresses, and files you import or export.'] },
      { id: 'use', title: '3. How We Use Data', bullets: ['Show location, flight path, status, and safety information on the map and flight display.', 'Generate, preview, run, pause, and resume missions created by you.', 'Control compatible DJI cameras and save mission records you request on the device.', 'Connect to a simulator on a network you specify and preview its virtual camera.', 'Diagnose device connectivity and runtime errors.'] },
      { id: 'permissions', title: '4. Device Permissions', body: ['OpenFly Go should request a permission only when a related feature needs it. You can change access at any time in iOS Settings.'], bullets: ['Location While Using the App: to show the device/controller position and support home-point and mission records.', 'Local Network: to connect through the same Wi-Fi network or personal hotspot to a UE/AirSim HIL environment you specify.', 'Bluetooth: only when genuinely required by a compatible DJI device or SDK connection flow.', 'Files: when you choose to import or export missions, logs, or task materials.'] },
      { id: 'storage', title: '5. Flight Logs, Local Storage, and Deletion', body: ['The OpenFly Go developer does not receive your flight logs. Flight logs, missions, settings, caches, and images you choose to save remain on your iPhone by default. These files leave the device only when you intentionally export, share, or send them.', 'Local data remains until you delete it in the app or Files, the app performs cleanup, you clear app data, or you uninstall the app. Uninstalling generally removes data inside the app sandbox, while files you exported or shared elsewhere must be deleted separately.', 'DJI Mobile SDK may independently create SDK logs or process obfuscated location or Analytics Data. This third-party processing by DJI SDK is subject to DJI’s privacy policy and is described separately below. OpenFly Go does not automatically upload DJI SDK flight records to an OpenFly-operated server.'] },
      { id: 'network', title: '6. Network Requests and Third Parties', body: ['The app does not automatically upload flight records to an OpenFly Go-operated cloud. Using DJI features or network features you configure can make the following requests:'], bullets: ['DJI SDK Analytics: SDK 4.16.2 contains collection, caching, and network-reporting code for registration, connection, flight, mission, and Virtual Stick events. OpenFly does not authorize DJI access to aircraft or controller hardware serial numbers. DJI’s interface says that authorization is off by default, although serial numbers may still be sent in mainland China for policy reasons.', 'DJI obfuscated location: DJI’s interface says that the mobile-device or DJI-product location is randomly offset by 5–10 km before it is used to update nearby fly zones. Access to this obfuscated location is enabled by default and cannot be disabled. OpenFly does not describe it as precise location.', 'DJI Warranty Logs: the SDK may store function calls, protocols or commands, timestamps, and results locally for warranty eligibility and product reliability. Under DJI terms, these logs are not automatically transmitted to DJI without the user’s prior consent.', 'DJI’s third-party processing is governed by its privacy policy: https://www.dji.com/policy', 'User-specified HIL: when you enter or discover a UE/AirSim address and start HIL, the app sends the state, control, and virtual-camera data you request to that device on the local network.', 'Apple and the App Store: downloads, updates, crash diagnostics, and system permissions are handled by Apple under its policies.'] },
      { id: 'sharing', title: '7. Sharing, Sale, and Tracking', body: ['We do not sell or rent personal information, display personalized advertising, or use data to track you across other companies’ apps or websites.', 'OpenFly Go does not automatically upload flight logs. Data you select is sent only when you intentionally use export, the system share sheet, a support email, or local-network simulation.', 'DJI SDK registration, obfuscated location, Analytics Data, and Warranty Logs are handled under DJI’s own policy and authorization mechanisms. This is separate from OpenFly Go receiving flight logs, except where disclosure is required by law or necessary to protect users and legal rights.'] },
      { id: 'security', title: '8. Security and Flight Safety', body: ['We use measures such as the iOS sandbox and constrained local-network connections to reduce unauthorized access. No storage or transmission method is completely secure. Avoid entering unnecessary sensitive information in logs, mission names, or custom addresses.', 'OpenFly Go is an engineering tool. It does not replace pilot judgment, visual observation, obstacle avoidance, return-to-home settings, or local law. Every mission must be verified by the operator before flight.'] },
      { id: 'children', title: '9. Children', body: ['OpenFly Go is intended for capable drone operators and researchers and is not directed to children. A guardian who believes a child has provided personal information may contact us using the method below.'] },
      { id: 'changes', title: '10. Changes and Contact', body: ['We may update this policy when features, laws, or third-party services change. The new “Last updated” date will appear on this page, and material changes will be communicated through the app or product page where reasonably possible.', 'For privacy questions, data requests, or complaints, email you_zhongrui@outlook.com. To protect your information, do not include unnecessary account credentials, precise location, or complete flight logs.'] },
    ],
  },
};

export default function PrivacyPage() {
  const { locale, setLocale } = useLocale();
  const text = copy[locale];
  return (
    <div className="min-h-screen bg-background text-foreground">
      <SiteHeader locale={locale} setLocale={setLocale} />
      <main>
        <section className="policy-hero">
          <div className="hero-grid" aria-hidden="true" />
          <div className="route-line route-line-a" aria-hidden="true" />
          <div className="page-width policy-hero-inner">
            <div className="eyebrow"><ShieldCheck size={16} />{text.label}</div>
            <h1>{text.title}</h1><p className="hero-summary">{text.summary}</p>
            <div className="date-row"><span>{text.effective}</span><span>{text.updated}</span></div>
            <div className="highlight-grid">{text.highlights.map((item) => <div key={item} className="highlight"><Check size={16} /><span>{item}</span></div>)}</div>
          </div>
        </section>
        <div className="page-width policy-layout">
          <aside><div className="toc"><div className="toc-label">{text.contents}</div><nav>{text.sections.map((section) => <a key={section.id} href={`#${section.id}`}><ChevronRight size={13} />{section.title}</a>)}</nav></div></aside>
          <article className="privacy-article">
            {text.sections.map((section) => <section key={section.id} id={section.id} className="policy-section"><h2>{section.title}</h2>{section.body?.map((paragraph) => <p key={paragraph}>{paragraph}</p>)}{section.bullets && <ul>{section.bullets.map((item) => <li key={item}>{item}</li>)}</ul>}</section>)}
            <div className="local-note"><MapPin size={20} /><p>{text.tip}</p></div>
          </article>
        </div>
      </main>
      <SiteFooter locale={locale} />
    </div>
  );
}
