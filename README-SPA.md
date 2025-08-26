# Creator Dashboard SPA

This README provides information about the Single-Page Application (SPA) implementation for the Gumroad creator dashboard.

## Quick Start

### Prerequisites

- Node.js 20.17.0
- Ruby 3.2.0+
- Rails 7.1+
- PostgreSQL

### Setup

1. **Install dependencies:**
   ```bash
   bundle install
   npm install
   ```

2. **Generate JavaScript routes:**
   ```bash
   bundle exec rake js:export
   ```

3. **Enable the SPA feature flag:**
   ```bash
   bundle exec rails console
   Feature.activate(:dashboard_spa_enabled)
   ```

4. **Start the development server:**
   ```bash
   bundle exec rails server
   npm run watch
   ```

5. **Access the SPA:**
   Navigate to `/dashboard/spa` in your browser.

## Architecture Overview

The SPA follows a modern React architecture with:

- **App Shell Pattern**: Persistent navigation with dynamic content
- **Client-Side Routing**: React Router for seamless navigation
- **Server-Side Rendering**: Initial page load is SSR for performance
- **Feature Flags**: Gradual rollout and instant fallback capability

## Key Components

### DashboardSPA
Main container component that handles routing and feature flag logic.

### DashboardLayout
Persistent app shell that contains:
- Navigation sidebar
- Main content area
- Footer actions

### Route Components
Individual page components for each route:
- `DashboardPage` - Main dashboard
- `SalesDashboard` - Sales analytics
- `ProductsPage` - Product management
- `NewProductPage` - Create new product
- `DiscoverPage` - Discover products
- `LibraryPage` - User's library

## Development

### Adding New Routes

1. Create the route component in `app/javascript/components/server-components/`
2. Add the route to the routes configuration in `DashboardSPA.tsx`
3. Add navigation item to `DashboardLayout.tsx`
4. Add CSS styles to `dashboard_spa.scss`

### Feature Flag Control

```ruby
# Enable for all users
Feature.activate(:dashboard_spa_enabled)

# Enable for specific user
Feature.activate_user(:dashboard_spa_enabled, user)

# Enable for percentage of users
Feature.activate_percentage(:dashboard_spa_enabled, 50)

# Disable
Feature.deactivate(:dashboard_spa_enabled)
```

### Styling

The SPA uses SCSS with a modular approach:
- Base styles in `dashboard_spa.scss`
- Component-specific styles in the same file
- Follows existing Gumroad design patterns

## Testing

### Unit Tests
```bash
npm test                    # Run all tests
npm run test:watch         # Watch mode
npm run test:coverage      # Coverage report
```

### E2E Tests (Playwright)
```bash
npm run test:e2e           # Run all E2E tests
npm run test:e2e:ui        # Interactive mode
npm run test:e2e:headed    # Headed mode
```

### Type Checking
```bash
npm run typecheck          # TypeScript compilation check
```

### Linting
```bash
npm run lint               # Check for issues
npm run lint:fix           # Auto-fix issues
```

## Performance

### Navigation Performance
- No full page reloads during navigation
- Instant route transitions
- Optimized bundle delivery

### Monitoring
- Navigation timing tracking
- Bundle size monitoring
- Performance metrics collection

## Accessibility

### Focus Management
- Automatic focus on route changes
- Logical tab order
- Screen reader support

### Keyboard Navigation
- Full keyboard support
- Escape key handling
- Arrow key navigation

## Troubleshooting

### Common Issues

1. **Routes not working**
   - Check if feature flag is enabled
   - Verify React Router configuration
   - Check browser console for errors

2. **Styling issues**
   - Ensure SCSS is properly imported
   - Check CSS class names
   - Verify Tailwind CSS integration

3. **Performance problems**
   - Monitor bundle sizes
   - Check for unnecessary re-renders
   - Verify code splitting

### Debug Mode

Enable debug logging:
```javascript
localStorage.setItem('dashboard-spa-debug', 'true');
```

### Feature Flag Issues

Check feature flag status:
```ruby
Feature.active?(:dashboard_spa_enabled, user)
```

## Deployment

### Production Setup

1. Ensure feature flag is properly configured
2. Run tests: `npm test && npm run test:e2e`
3. Build assets: `npm run build`
4. Deploy with feature flag disabled initially
5. Gradually enable via feature flags

### Rollback Plan

If issues arise:
1. Disable feature flag immediately
2. Users automatically fall back to server-rendered dashboard
3. No data loss or functionality impact

## Contributing

### Code Standards

- Follow existing TypeScript patterns
- Use React hooks for state management
- Implement proper error boundaries
- Add comprehensive tests
- Follow accessibility guidelines

### Pull Request Process

1. Create feature branch
2. Implement changes with tests
3. Ensure all tests pass
4. Update documentation
5. Submit PR with clear description

## Support

### Documentation
- [Creator Dashboard SPA Guide](docs/creator-dashboard-spa.md)
- [Feature Flag System](docs/feature-flags.md)
- [Testing Guide](docs/testing.md)

### Getting Help

1. Check this README
2. Review the main documentation
3. Check existing issues
4. Contact the development team

## Roadmap

### Phase 1 (Current)
- ✅ Basic SPA structure
- ✅ Client-side routing
- ✅ Feature flag system
- ✅ Basic styling

### Phase 2 (Next)
- Data fetching implementation
- Advanced caching strategies
- Performance optimizations
- Enhanced analytics

### Phase 3 (Future)
- Offline support
- Progressive Web App features
- Advanced code splitting
- Virtual scrolling

## License

This project is part of the Gumroad codebase and follows the same licensing terms.
