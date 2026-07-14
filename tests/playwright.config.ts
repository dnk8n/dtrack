import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './e2e',
  timeout: 60_000,
  retries: process.env.CI ? 1 : 0,
  // The suites drive one shared UI/database; keep them sequential.
  workers: 1,
  use: {
    baseURL: process.env.DTRACK_TEST_APP_URI ?? 'http://localhost:5174',
    trace: 'retain-on-failure',
  },
  reporter: process.env.CI ? [['list'], ['html', { open: 'never' }]] : [['list']],
  projects: [{ name: 'chromium', use: { browserName: 'chromium' } }],
});
