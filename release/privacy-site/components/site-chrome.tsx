'use client';

import { Radio } from 'lucide-react';
import Link from 'next/link';
import { LanguageSwitch, type Locale } from './locale';

export function SiteHeader({ locale, setLocale }: { locale: Locale; setLocale: (locale: Locale) => void }) {
  const labels = locale === 'zh'
    ? { home: '首页', privacy: '隐私政策', support: '支持' }
    : { home: 'Home', privacy: 'Privacy', support: 'Support' };

  return (
    <header className="site-header">
      <div className="header-inner">
        <Link href="/" className="brand" aria-label="OpenFly Go home">
          <span className="brand-mark" aria-hidden="true"><Radio size={17} /></span>
          <span>OpenFly Go</span>
        </Link>
        <nav className="site-nav" aria-label={locale === 'zh' ? '主导航' : 'Primary navigation'}>
          <Link href="/">{labels.home}</Link>
          <Link href="/privacy">{labels.privacy}</Link>
          <Link href="/support">{labels.support}</Link>
        </nav>
        <LanguageSwitch locale={locale} setLocale={setLocale} />
      </div>
    </header>
  );
}

export function SiteFooter({ locale }: { locale: Locale }) {
  return (
    <footer>
      <div className="footer-inner">
        <span className="footer-brand">OpenFly Go</span>
        <span>{locale === 'zh'
          ? '面向无人机采集、航线规划与仿真的移动工作台'
          : 'A mobile workspace for drone capture, mission planning, and simulation'}</span>
      </div>
    </footer>
  );
}
