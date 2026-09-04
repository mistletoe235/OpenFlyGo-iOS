'use client';

import { ExternalLink, FileText, LifeBuoy, Radio, ShieldCheck, Smartphone } from 'lucide-react';
import Link from 'next/link';
import { useLocale } from '@/components/locale';
import { SiteFooter, SiteHeader } from '@/components/site-chrome';

const copy = {
  zh: {
    eyebrow: 'OpenFly Go 支持', title: '飞行前先确认连接、兼容性与安全边界。',
    intro: 'OpenFly Go 是工程与研究工具。部分功能需要兼容 DJI 飞行器、遥控器、固件以及 DJI iOS Mobile SDK 支持。',
    cards: [
      ['设备与连接', '确认飞行器、遥控器和手机连接正常，并在 DJI 官方应用中完成必要的激活、登录和固件检查。'],
      ['日志与文件', '航线、日志和截图默认保存在本机；可通过“文件”App 导出后随问题描述一起提供。'],
      ['隐私与权限', '定位和本地网络只应在对应功能需要时授权；你可以随时在 iOS“设置”中修改。'],
    ],
    compatibility: '兼容性说明', compatibilityBody: 'iOS 版本基于 DJI iOS Mobile SDK V4。具体飞行器支持范围取决于 DJI SDK、遥控器连接方式与固件；不应把 Android MSDK V5 机型支持直接等同于 iOS 支持。',
    contact: '联系支持', contactBody: '请发送邮件至 you_zhongrui@outlook.com，并附上设备型号、系统版本、复现步骤和必要的日志片段。发送前请删除账号凭据、精确位置等无关敏感信息。',
    privacy: '查看隐私政策', safety: '飞行安全', safetyBody: 'iOS 版由 OpenFly 进行高层航迹跟踪，并通过 DJI 官方 MSDK Virtual Stick 提交速度设定；DJI 飞控负责姿态稳定、地理围栏、失控保护和返航，飞手可随时接管。任何航线或自动控制都不能替代现场观察和当地法规。',
  },
  en: {
    eyebrow: 'OpenFly Go Support', title: 'Confirm connectivity, compatibility, and safety boundaries before flight.',
    intro: 'OpenFly Go is an engineering and research tool. Some features require a compatible DJI aircraft, controller, firmware, and DJI iOS Mobile SDK support.',
    cards: [
      ['Devices and connectivity', 'Confirm that the aircraft, controller, and phone are connected, and complete required activation, sign-in, and firmware checks in the official DJI app.'],
      ['Logs and files', 'Missions, logs, and screenshots are stored locally by default. Export them through Files and include them with your issue report.'],
      ['Privacy and permissions', 'Location and local-network access should be granted only when a related feature needs them. You can change access in iOS Settings.'],
    ],
    compatibility: 'Compatibility', compatibilityBody: 'The iOS version is based on DJI iOS Mobile SDK V4. Aircraft support depends on the DJI SDK, controller connection, and firmware; Android MSDK V5 support must not be assumed to apply to iOS.',
    contact: 'Contact support', contactBody: 'Email you_zhongrui@outlook.com with the device model, OS version, reproduction steps, and only the log excerpts needed to diagnose the issue. Remove credentials, precise location, and unrelated sensitive information before sending.',
    privacy: 'Read the privacy policy', safety: 'Flight safety', safetyBody: 'On iOS, OpenFly performs high-level path tracking and submits velocity setpoints through DJI’s official MSDK Virtual Stick interface. The DJI flight controller retains stabilization, geofencing, failsafe, return-to-home, and pilot takeover. No mission replaces on-site observation or local law.',
  },
} as const;

const icons = [Smartphone, FileText, ShieldCheck];

export default function SupportPage() {
  const { locale, setLocale } = useLocale();
  const text = copy[locale];
  return <div className="min-h-screen bg-background text-foreground">
    <SiteHeader locale={locale} setLocale={setLocale} />
    <main>
      <section className="subpage-hero"><div className="page-width"><div className="eyebrow"><LifeBuoy size={16} />{text.eyebrow}</div><h1>{text.title}</h1><p className="hero-summary">{text.intro}</p></div></section>
      <div className="page-width support-content">
        <div className="support-grid">{text.cards.map(([title, body], index) => { const Icon = icons[index]; return <article className="support-card" key={title}><Icon size={22} /><h2>{title}</h2><p>{body}</p></article>; })}</div>
        <section className="support-section"><Radio size={22} /><div><h2>{text.compatibility}</h2><p>{text.compatibilityBody}</p></div></section>
        <section className="support-section"><LifeBuoy size={22} /><div><h2>{text.contact}</h2><p>{text.contactBody}</p><a className="support-email" href="mailto:you_zhongrui@outlook.com">you_zhongrui@outlook.com</a></div></section>
        <section className="support-section warning"><ShieldCheck size={22} /><div><h2>{text.safety}</h2><p>{text.safetyBody}</p></div></section>
        <Link href="/privacy" className="inline-link">{text.privacy}<ExternalLink size={15} /></Link>
      </div>
    </main>
    <SiteFooter locale={locale} />
  </div>;
}
