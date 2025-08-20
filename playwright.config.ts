import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './spec/e2e',
  use: {
    baseURL: 'http://localhost:3000',
  },
});
