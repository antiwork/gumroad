import { test, expect } from '@playwright/test';

test.describe('Dashboard SPA Navigation', () => {
  test('should navigate between sections without page reloads', async ({ page }) => {
    await page.goto('/dashboard/spa');

    // Check SPA loads
    await expect(page.locator('.dashboard-spa-container')).toBeVisible();

    // Navigate to Analytics
    await page.click('[data-testid="nav-sales-analytics"]');
    await expect(page).toHaveURL(/.*dashboard\/sales/);
    await expect(page.locator('.analytics-page-wrapper')).toBeVisible();

    // Navigate to Audience
    await page.click('[data-testid="nav-audience"]');
    await expect(page).toHaveURL(/.*dashboard\/audience/);
    await expect(page.locator('.audience-page-wrapper')).toBeVisible();

    // Navigate to UTM Links
    await page.click('[data-testid="nav-utm-links"]');
    await expect(page).toHaveURL(/.*dashboard\/utm_links/);
    await expect(page.locator('.utm-links-page-wrapper')).toBeVisible();
  });
});
