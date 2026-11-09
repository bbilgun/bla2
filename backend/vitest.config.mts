import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    include: ['test/**/*.test.ts'],
    // Starts one in-memory mongod for the whole run; each test file gets its own database.
    globalSetup: ['test/global-setup.ts'],
    env: { LOG_LEVEL: 'silent' },
    testTimeout: 20_000,
    hookTimeout: 120_000, // first run downloads the mongod binary
  },
});
