/**
 * Deployment settings, resolved once at startup.
 *
 * A production image is built once (in CI) and published publicly, so it
 * carries no tenant, client or host. Its container writes /config.js at start
 * from environment variables (dtrack/ui/40-dtrack-config.sh),
 * which sets window.__DTRACK_CONFIG__ before the app loads. Local dev, debug
 * and test builds still bake the values in as VITE_* build args; those are the
 * fallback when a runtime value is absent.
 */
interface RuntimeConfig {
  MSAL_CLIENT_ID?: string;
  MSAL_AUTHORITY?: string;
  APP_BASE_URI?: string;
  API_BASE_URI?: string;
  PALETTE_PRIMARY?: string;
  PALETTE_SECONDARY?: string;
}

declare global {
  interface Window {
    __DTRACK_CONFIG__?: RuntimeConfig;
  }
}

const runtime: RuntimeConfig = window.__DTRACK_CONFIG__ ?? {};
const env = import.meta.env;

export const config = {
  msalClientId: runtime.MSAL_CLIENT_ID || env.VITE_MSAL_CLIENT_ID,
  msalAuthority: runtime.MSAL_AUTHORITY || env.VITE_MSAL_AUTHORITY,
  appBaseUri: runtime.APP_BASE_URI || env.VITE_APP_BASE_URI,
  apiBaseUri: runtime.API_BASE_URI || env.VITE_API_BASE_URI,
  palettePrimary: runtime.PALETTE_PRIMARY || env.VITE_PALETTE_PRIMARY || '#330808',
  paletteSecondary: runtime.PALETTE_SECONDARY || env.VITE_PALETTE_SECONDARY || '#A32122',
};
