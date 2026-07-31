import type { Metadata, Viewport } from 'next';
import './globales.css';

export const metadata: Metadata = {
  title: 'Chasqui Pet',
  description: 'Sistema de la clínica veterinaria Chasqui Pet.',
};

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  themeColor: '#0b1016',
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="es-CO">
      <body>{children}</body>
    </html>
  );
}
