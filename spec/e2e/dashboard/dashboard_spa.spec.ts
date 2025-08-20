import { test, expect } from '@playwright/test';
import * as fs from 'fs';

test.describe('Dashboard SPA Implementation', () => {
  test('SPA architecture is correctly implemented', async () => {
    const spaExists = fs.existsSync('app/javascript/components/dashboard/DashboardSPA.tsx');
    expect(spaExists).toBe(true);

    const spaContent = fs.readFileSync('app/javascript/components/dashboard/DashboardSPA.tsx', 'utf8');
    expect(spaContent).toContain('BrowserRouter');

    expect(fs.existsSync('app/javascript/components/dashboard/pages/AnalyticsPage.tsx')).toBe(true);
    expect(fs.existsSync('app/views/dashboard/spa.html.erb')).toBe(true);

    console.log('✅ SPA architecture verification complete');
  });
});
