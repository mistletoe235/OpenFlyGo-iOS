import type { Metadata } from 'next';

export const metadata: Metadata = {
  title: 'Support · 支持 | OpenFly Go',
  description: 'Support and compatibility information for OpenFly Go.',
};

export default function SupportLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return children;
}
