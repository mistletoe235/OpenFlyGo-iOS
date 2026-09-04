'use client';

import { ArrowRight, FileText, Map, Route, ShieldCheck, Waves } from 'lucide-react';
import Link from 'next/link';
import { useLocale } from '@/components/locale';
import { SiteFooter, SiteHeader } from '@/components/site-chrome';

const copy = {
  zh: {
    eyebrow: '开放的无人机移动工作台',
    title: '让消费级无人机也能完成专业的采集与仿真。',
    summary: 'OpenFly Go 将实时飞行状态、区域航线和硬件在环仿真放在一个清晰的移动界面里。',
    action: '查看隐私政策',
    support: '获取支持',
    section: '从航线规划到安全执行',
    sectionLead: '一个面向真实飞行与研究验证的统一入口，功能边界保持清晰，安全状态始终可见。',
    features: [
      ['区域航线', '在地图上规划正射、倾斜与补采任务，保存并导入导出任务资料。'],
      ['飞行工作台', '集中呈现兼容 DJI 飞行器的图传、位置、姿态、电量与任务状态。'],
      ['HIL 仿真', '通过局域网或手机热点连接 UE/AirSim，接入虚拟相机和飞行状态。'],
      ['任务与日志', '保存任务版本、飞行记录和采集资料，并通过“文件”App 导入导出。'],
    ],
    privacyTitle: '默认本地处理，主动连接才离开设备。',
    privacyBody: 'OpenFly Go 不使用广告或跨应用跟踪。飞行记录和任务默认保存在你的设备中；DJI 连接和局域网仿真按隐私政策处理。',
    privacyLink: '阅读完整政策',
  },
  en: {
    eyebrow: 'An open mobile workspace for drones',
    title: 'Professional capture and simulation for accessible drones.',
    summary: 'OpenFly Go brings live flight state, area missions, and hardware-in-the-loop simulation into one focused mobile interface.',
    action: 'Read the privacy policy',
    support: 'Get support',
    section: 'From mission planning to safe execution',
    sectionLead: 'One entry point for real-world flight and research validation, with clear capability boundaries and visible safety state.',
    features: [
      ['Area missions', 'Plan orthographic, oblique, and recapture missions on a map, then save, import, and export mission files.'],
      ['Flight workspace', 'View video, position, attitude, battery, and mission state from compatible DJI aircraft in one place.'],
      ['HIL simulation', 'Connect to UE/AirSim through a local network or personal hotspot for virtual camera and flight state.'],
      ['Tasks and logs', 'Save mission versions, flight records, and capture materials, then import or export them through Files.'],
    ],
    privacyTitle: 'Local by default. Networked only when you choose.',
    privacyBody: 'OpenFly Go does not use advertising or cross-app tracking. Flight records and missions stay on your device by default; DJI connectivity and local simulation are handled as described in the privacy policy.',
    privacyLink: 'Read the full policy',
  },
} as const;

const icons = [Route, Map, Waves, FileText];

export default function Home() {
  const { locale, setLocale } = useLocale();
  const text = copy[locale];

  return (
    <div className="min-h-screen bg-background text-foreground">
      <SiteHeader locale={locale} setLocale={setLocale} />
      <main>
        <section className="home-hero">
          <div className="hero-grid" aria-hidden="true" />
          <div className="route-line route-line-a" aria-hidden="true" />
          <div className="route-line route-line-b" aria-hidden="true" />
          <div className="page-width home-hero-inner">
            <div className="home-copy">
              <div className="eyebrow"><span className="live-dot" />{text.eyebrow}</div>
              <h1>{text.title}</h1>
              <p className="hero-summary">{text.summary}</p>
              <div className="hero-actions">
                <Link href="/privacy" className="primary-action">{text.action}<ArrowRight size={17} /></Link>
                <Link href="/support" className="secondary-action">{text.support}</Link>
              </div>
            </div>
            <div className="flight-card" aria-hidden="true">
              <div className="flight-card-top"><span>OPENFLY / GO</span><span className="status-pill">READY</span></div>
              <div className="flight-map">
                <span className="flight-route route-one" />
                <span className="flight-route route-two" />
                <span className="flight-node node-a" />
                <span className="flight-node node-b" />
                <span className="flight-node node-c" />
              </div>
              <div className="flight-metrics"><span>H 42.8 m</span><span>VS 0.0 m/s</span><span>GPS 18</span></div>
            </div>
          </div>
        </section>

        <section className="page-width feature-section">
          <div className="section-heading"><p>{text.section}</p><span>{text.sectionLead}</span></div>
          <div className="feature-grid">
            {text.features.map(([title, body], index) => {
              const Icon = icons[index];
              return <article className="feature-card" key={title}><Icon size={21} /><h2>{title}</h2><p>{body}</p></article>;
            })}
          </div>
        </section>

        <section className="page-width privacy-callout">
          <div className="privacy-icon"><ShieldCheck size={27} /></div>
          <div><h2>{text.privacyTitle}</h2><p>{text.privacyBody}</p></div>
          <Link href="/privacy">{text.privacyLink}<ArrowRight size={16} /></Link>
        </section>
      </main>
      <SiteFooter locale={locale} />
    </div>
  );
}
