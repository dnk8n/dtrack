import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['api/**/*.test.ts'],
    // API tests hit a shared database; run files sequentially so fixtures
    // written by one file can't race another file's assertions.
    fileParallelism: false,
    testTimeout: 30_000,
    hookTimeout: 60_000,
  },
});
