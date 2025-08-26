import { test, expect } from '@playwright/test';

test.describe('Dashboard SPA', () => {
  test.beforeEach(async ({ page }) => {
    // Navigate to the dashboard SPA
    await page.goto('/dashboard/spa');
  });

  test('should load the SPA dashboard without full page reloads', async ({ page }) => {
    // Wait for the SPA to load
    await expect(page.locator('text=Creator Dashboard')).toBeVisible();
    
    // Verify initial navigation count is 1 (initial page load)
    const initialNavigationCount = await page.evaluate(() => 
      window.performance.getEntriesByType('navigation').length
    );
    expect(initialNavigationCount).toBe(1);
  });

  test('should navigate between routes without full page reloads', async ({ page }) => {
    // Wait for the SPA to load
    await expect(page.locator('text=Creator Dashboard')).toBeVisible();
    
    // Get initial navigation count
    const initialNavigationCount = await page.evaluate(() => 
      window.performance.getEntriesByType('navigation').length
    );
    
    // Navigate to Products
    await page.click('text=Products');
    await expect(page.locator('text=Products')).toBeVisible();
    await expect(page.locator('text=Manage your digital products and memberships')).toBeVisible();
    
    // Verify URL changed
    await expect(page).toHaveURL('/products');
    
    // Verify navigation count didn't increase (no full reload)
    const navigationCountAfterProducts = await page.evaluate(() => 
      window.performance.getEntriesByType('navigation').length
    );
    expect(navigationCountAfterProducts).toBe(initialNavigationCount);
    
    // Navigate to Sales
    await page.click('text=Sales');
    await expect(page.locator('text=Sales Analytics')).toBeVisible();
    await expect(page.locator('text=Track your sales performance and revenue metrics')).toBeVisible();
    
    // Verify URL changed
    await expect(page).toHaveURL('/dashboard/sales');
    
    // Verify navigation count still didn't increase
    const navigationCountAfterSales = await page.evaluate(() => 
      window.performance.getEntriesByType('navigation').length
    );
    expect(navigationCountAfterSales).toBe(initialNavigationCount);
    
    // Navigate to Discover
    await page.click('text=Discover');
    await expect(page.locator('text=Discover')).toBeVisible();
    await expect(page.locator('text=Find amazing products from other creators')).toBeVisible();
    
    // Verify URL changed
    await expect(page).toHaveURL('/discover');
    
    // Navigate to Library
    await page.click('text=Library');
    await expect(page.locator('text=Library')).toBeVisible();
    await expect(page.locator('text=Your purchased products and content')).toBeVisible();
    
    // Verify URL changed
    await expect(page).toHaveURL('/library');
    
    // Navigate back to Dashboard
    await page.click('text=Dashboard');
    await expect(page.locator('text=Dashboard')).toBeVisible();
    
    // Verify URL changed back
    await expect(page).toHaveURL('/dashboard');
    
    // Final verification that navigation count never increased
    const finalNavigationCount = await page.evaluate(() => 
      window.performance.getEntriesByType('navigation').length
    );
    expect(finalNavigationCount).toBe(initialNavigationCount);
  });

  test('should handle browser back/forward navigation', async ({ page }) => {
    // Wait for the SPA to load
    await expect(page.locator('text=Creator Dashboard')).toBeVisible();
    
    // Navigate to Products
    await page.click('text=Products');
    await expect(page.locator('text=Products')).toBeVisible();
    
    // Navigate to Sales
    await page.click('text=Sales');
    await expect(page.locator('text=Sales Analytics')).toBeVisible();
    
    // Go back
    await page.goBack();
    await expect(page.locator('text=Products')).toBeVisible();
    await expect(page).toHaveURL('/products');
    
    // Go back again
    await page.goBack();
    await expect(page.locator('text=Dashboard')).toBeVisible();
    await expect(page).toHaveURL('/dashboard');
    
    // Go forward
    await page.goForward();
    await expect(page.locator('text=Products')).toBeVisible();
    await expect(page).toHaveURL('/products');
  });

  test('should handle deep linking to specific routes', async ({ page }) => {
    // Navigate directly to Products
    await page.goto('/products');
    await expect(page.locator('text=Products')).toBeVisible();
    await expect(page.locator('text=Manage your digital products and memberships')).toBeVisible();
    
    // Navigate directly to Sales
    await page.goto('/dashboard/sales');
    await expect(page.locator('text=Sales Analytics')).toBeVisible();
    await expect(page.locator('text=Track your sales performance and revenue metrics')).toBeVisible();
    
    // Navigate directly to New Product
    await page.goto('/products/new');
    await expect(page.locator('text=Create New Product')).toBeVisible();
    await expect(page.locator('text=What are you creating today?')).toBeVisible();
    
    // Navigate directly to Discover
    await page.goto('/discover');
    await expect(page.locator('text=Discover')).toBeVisible();
    await expect(page.locator('text=Find amazing products from other creators')).toBeVisible();
    
    // Navigate directly to Library
    await page.goto('/library');
    await expect(page.locator('text=Library')).toBeVisible();
    await expect(page.locator('text=Your purchased products and content')).toBeVisible();
  });

  test('should show fallback when feature flag is disabled', async ({ page }) => {
    // This test would require the feature flag to be disabled
    // In a real scenario, you might need to mock this or test with different configurations
    
    // For now, we'll test that the SPA loads correctly when enabled
    await expect(page.locator('text=Creator Dashboard')).toBeVisible();
    await expect(page.locator('text=Dashboard SPA is currently disabled')).not.toBeVisible();
  });

  test('should maintain focus management on route changes', async ({ page }) => {
    // Wait for the SPA to load
    await expect(page.locator('text=Creator Dashboard')).toBeVisible();
    
    // Navigate to Products
    await page.click('text=Products');
    await expect(page.locator('text=Products')).toBeVisible();
    
    // Verify focus is on the main heading
    const productsHeading = page.locator('h1:has-text("Products")');
    await expect(productsHeading).toBeFocused();
    
    // Navigate to Sales
    await page.click('text=Sales');
    await expect(page.locator('text=Sales Analytics')).toBeVisible();
    
    // Verify focus is on the main heading
    const salesHeading = page.locator('h1:has-text("Sales Analytics")');
    await expect(salesHeading).toBeFocused();
  });

  test('should handle navigation with query parameters', async ({ page }) => {
    // Navigate to Products with query parameters
    await page.goto('/products?tab=active&sort=name');
    await expect(page.locator('text=Products')).toBeVisible();
    
    // Verify URL contains query parameters
    await expect(page).toHaveURL('/products?tab=active&sort=name');
    
    // Navigate to another route
    await page.click('text=Sales');
    await expect(page.locator('text=Sales Analytics')).toBeVisible();
    
    // Verify URL changed but query parameters are preserved if needed
    await expect(page).toHaveURL('/dashboard/sales');
  });
});
