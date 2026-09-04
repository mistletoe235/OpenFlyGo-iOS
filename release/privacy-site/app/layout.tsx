import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  metadataBase: new URL('https://app.openflygo.com'),
  title: 'OpenFly Go',
  description: 'Drone capture, mission planning, and simulation in one mobile workspace.',
  applicationName: 'OpenFly Go',
  openGraph: {
    title: 'OpenFly Go',
    description: 'Drone capture, mission planning, and simulation in one mobile workspace.',
    type: 'website',
    images: [{ url: '/og.png', width: 1200, height: 630, alt: 'OpenFly Go Privacy Policy · 隐私政策' }],
  },
  twitter: {
    card: 'summary_large_image',
    title: 'OpenFly Go',
    description: 'Drone capture, mission planning, and simulation in one mobile workspace.',
    images: ['/og.png'],
  },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="zh-CN" suppressHydrationWarning><body>{children}</body></html>;
}
