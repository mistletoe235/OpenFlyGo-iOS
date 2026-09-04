import type { Metadata } from 'next';

export const metadata: Metadata = {
  title: 'Privacy Policy · 隐私政策 | OpenFly Go',
  description: 'How OpenFly Go for iOS processes location, flight, mission, image, and simulation data.',
};

export default function PrivacyLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return children;
}
