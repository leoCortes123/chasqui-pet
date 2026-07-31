import type { NextConfig } from 'next';

const nextConfig: NextConfig = {
  // El Dockerfile copia .next/standalone y arranca `node server.js`.
  output: 'standalone',

  reactStrictMode: true,

  // `pg` es una dependencia nativa de servidor: no debe pasar por el bundler.
  serverExternalPackages: ['pg'],

  // La pantalla pública no cachea nada: siempre datos frescos.
  poweredByHeader: false,
};

export default nextConfig;
