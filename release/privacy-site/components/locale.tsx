'use client';

import { Globe2 } from 'lucide-react';
import { useEffect, useState } from 'react';

export type Locale = 'zh' | 'en';

export function useLocale() {
  const [locale, setLocale] = useState<Locale>('zh');

  useEffect(() => {
    const timer = window.setTimeout(() => {
      const stored = window.localStorage.getItem('openfly-site-locale');
      if (stored === 'zh' || stored === 'en') {
        setLocale(stored);
        return;
      }
      const detected = navigator.languages.some((value) => value.toLowerCase().startsWith('zh')) ? 'zh' : 'en';
      setLocale(detected);
    }, 0);
    return () => window.clearTimeout(timer);
  }, []);

  useEffect(() => {
    document.documentElement.lang = locale === 'zh' ? 'zh-CN' : 'en';
    window.localStorage.setItem('openfly-site-locale', locale);
  }, [locale]);

  return { locale, setLocale };
}

export function LanguageSwitch({ locale, setLocale }: {
  locale: Locale;
  setLocale: (locale: Locale) => void;
}) {
  return (
    <div className="language-switch" aria-label={locale === 'zh' ? '语言选择' : 'Language selector'}>
      <Globe2 size={15} aria-hidden="true" />
      <button className={locale === 'zh' ? 'active' : ''} onClick={() => setLocale('zh')} aria-pressed={locale === 'zh'}>中文</button>
      <span aria-hidden="true">/</span>
      <button className={locale === 'en' ? 'active' : ''} onClick={() => setLocale('en')} aria-pressed={locale === 'en'}>EN</button>
    </div>
  );
}
