# Creator Dashboard SPA

This document describes the implementation of the Single-Page Application (SPA) for the Gumroad creator dashboard.

## Overview

The creator dashboard SPA converts the traditional multi-page dashboard into a single-page application with client-side routing. This provides instant navigation between dashboard pages without full page reloads while preserving all existing functionality.

## Architecture

### Core Components

- **DashboardSPA**: Main SPA container component that handles routing
- **DashboardLayout**: Persistent app shell with navigation and main content area
- **Route Components**: Individual page components for each route

### Technology Stack

- **React 18**: Core UI framework
- **React Router 6**: Client-side routing with SSR support
- **TypeScript**: Type safety and development experience
- **SCSS**: Styling with modern CSS features
- **Feature Flags**: Gradual rollout and fallback capability

## Routes

The SPA handles the following routes:

| Route | Component | Description |
|-------|-----------|-------------|
| `/dashboard` | DashboardPage | Main dashboard overview |
| `/dashboard/sales` | SalesDashboard | Sales analytics and metrics |
| `/products` | ProductsPage | Product management |
| `/products/new` | NewProductPage | Create new product |
| `/discover` | DiscoverPage | Discover other creators' products |
| `/library` | LibraryPage | User's purchased content |

## Implementation Details

### App Shell Pattern

The SPA uses an app shell pattern where:
- Navigation sidebar remains persistent across route changes
- Only the main content area updates
- Header and footer stay consistent

### Client-Side Routing

- Uses React Router for navigation
- Preserves browser back/forward functionality
- Maintains URL structure for deep linking
- No full page reloads during navigation

### Server-Side Rendering

- Initial page load is server-rendered for SEO and performance
- Subsequent navigation is handled client-side
- Hydration ensures smooth transition from SSR to SPA

### Feature Flag System

The SPA is controlled by the `DASHBOARD_SPA_ENABLED` feature flag:

```ruby
# Enable for all users
Feature.activate(:dashboard_spa_enabled)

# Enable for specific user
Feature.activate_user(:dashboard_spa_enabled, user)

# Enable for percentage of users
Feature.activate_percentage(:dashboard_spa_enabled, 50)
```

When disabled, users fall back to the traditional server-rendered dashboard.

## Data Fetching Strategy

### Current Implementation

- Route components are placeholder implementations
- Data fetching will be implemented in future iterations
- Existing JSON APIs will be leveraged where available

### Future Implementation

- Use React Router loaders for data fetching
- Implement caching strategies for repeated queries
- Add error boundaries and retry mechanisms

## Analytics Integration

### Page View Tracking

- Client-side page views are tracked on route changes
- Uses existing Google Analytics integration
- Maintains analytics parity with server-rendered pages

### Performance Monitoring

- Navigation performance is monitored
- Ensures no full page reloads occur
- Tracks route change timing

## Accessibility Features

### Focus Management

- Focus moves to main heading on route changes
- Maintains logical tab order
- Screen reader announcements for route changes

### Keyboard Navigation

- Full keyboard navigation support
- Escape key handling for modals
- Arrow key navigation in lists

## Performance Considerations

### Code Splitting

- Route components are lazy-loaded
- Reduces initial bundle size
- Improves first-load performance

### Caching

- HTTP caching for static assets
- Client-side caching for API responses
- Optimized bundle delivery

## Testing Strategy

### Unit Tests

- Component rendering and behavior
- Feature flag functionality
- Navigation logic

### Integration Tests

- Route transitions
- State management
- API integration

### E2E Tests (Playwright)

- Full user journey testing
- Navigation performance verification
- Cross-browser compatibility

## Deployment and Rollout

### Feature Flag Control

1. **Development**: Always enabled
2. **Staging**: Enabled for testing
3. **Production**: Gradual rollout via feature flags

### Rollback Plan

If issues arise:
1. Disable feature flag for affected users
2. Users automatically fall back to server-rendered dashboard
3. No data loss or functionality impact

## Adding New Routes

### 1. Create Route Component

```tsx
export const NewRoutePage: React.FC = () => {
  const { dashboard_spa_enabled } = useFeatureFlags();
  
  if (!dashboard_spa_enabled) {
    return <div>SPA disabled fallback</div>;
  }
  
  return (
    <div className="new-route-page">
      <h1>New Route</h1>
      {/* Route content */}
    </div>
  );
};
```

### 2. Add to Routes Configuration

```tsx
const routes: RouteObject[] = [
  // ... existing routes
  {
    path: "/new-route",
    element: <DashboardLayout />,
    children: [
      {
        index: true,
        element: <NewRoutePage />,
      },
    ],
  },
];
```

### 3. Add Navigation Item

```tsx
const NAV_ITEMS = [
  // ... existing items
  { path: "/new-route", label: "New Route", icon: "icon-name" as const },
];
```

### 4. Add CSS Styles

```scss
.new-route-page {
  // Route-specific styles
}
```

## Troubleshooting

### Common Issues

1. **Routes not working**: Check feature flag is enabled
2. **Navigation errors**: Verify React Router configuration
3. **Styling issues**: Ensure SCSS is properly imported

### Debug Mode

Enable debug logging by setting:
```javascript
localStorage.setItem('dashboard-spa-debug', 'true');
```

### Performance Issues

- Check for unnecessary re-renders
- Verify code splitting is working
- Monitor bundle sizes

## Future Enhancements

### Planned Features

- Advanced caching strategies
- Offline support
- Progressive Web App capabilities
- Enhanced analytics integration

### Performance Improvements

- Virtual scrolling for large lists
- Image optimization and lazy loading
- Advanced code splitting strategies

## Contributing

### Development Setup

1. Ensure feature flag is enabled
2. Run `npm run watch` for development
3. Test with `npm test` and `npm run test:e2e`

### Code Standards

- Follow existing TypeScript patterns
- Use React hooks for state management
- Implement proper error boundaries
- Add comprehensive tests

## Support

For questions or issues:
1. Check this documentation
2. Review test coverage
3. Consult the feature flag system
4. Contact the development team
