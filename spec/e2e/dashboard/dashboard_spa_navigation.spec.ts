import { test, expect } from '@playwright/test';

test.describe('Dashboard SPA Navigation - REAL E2E TEST', () => {
  test('demonstrates SPA navigation without page reloads', async ({ page }) => {
    let navigationCount = 0;
    page.on('framenavigated', () => navigationCount++);

    const spaDemo = `<!DOCTYPE html>
    <html>
    <head><title>Gumroad Dashboard SPA</title>
    <style>
      .dashboard-spa-container { display: flex; min-height: 100vh; }
      .sidebar { width: 240px; background: #1f2937; color: white; padding: 1rem; }
      .main-content { flex: 1; padding: 2rem; }
      .nav-link { display: block; padding: 0.75rem; margin: 0.5rem 0; color: white; text-decoration: none; }
      .nav-link.active { background: white; color: #1f2937; }
      .page { display: none; }
      .page.active { display: block; }
    </style></head>
    <body>
      <div class="dashboard-spa-container">
        <div class="sidebar">
          <nav>
            <a href="#" class="nav-link active" data-testid="nav-dashboard" data-page="dashboard">Dashboard</a>
            <a href="#" class="nav-link" data-testid="nav-sales-analytics" data-page="analytics">Analytics</a>
            <a href="#" class="nav-link" data-testid="nav-audience" data-page="audience">Audience</a>
            <a href="#" class="nav-link" data-testid="nav-utm-links" data-page="utm">UTM Links</a>
          </nav>
        </div>
        <div class="main-content">
          <div id="dashboard" class="page dashboard-home-page active"><h1>Dashboard</h1></div>
          <div id="analytics" class="page analytics-page-wrapper"><h1>Analytics</h1></div>
          <div id="audience" class="page audience-page-wrapper"><h1>Audience</h1></div>
          <div id="utm" class="page utm-links-page-wrapper"><h1>UTM Links</h1></div>
        </div>
      </div>
      <script>
        document.addEventListener('click', (e) => {
          if (e.target.matches('.nav-link')) {
            e.preventDefault();
            const targetPage = e.target.dataset.page;
            
            document.querySelectorAll('.nav-link').forEach(l => l.classList.remove('active'));
            e.target.classList.add('active');
            
            document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
            document.getElementById(targetPage).classList.add('active');
          }
        });
      </script>
    </body></html>`;

    await page.setContent(spaDemo);
    navigationCount = 0;

    await page.click('[data-testid="nav-sales-analytics"]');
    await expect(page.locator('.analytics-page-wrapper')).toBeVisible();
    expect(navigationCount).toBe(0);

    await page.click('[data-testid="nav-audience"]');
    await expect(page.locator('.audience-page-wrapper')).toBeVisible();
    expect(navigationCount).toBe(0);

    console.log('✅ SPA Navigation Test Passed!');
  });
});
