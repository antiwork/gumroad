import React from "react";
import { render, screen } from "@testing-library/react";
import { BrowserRouter } from "react-router-dom";

import DashboardSPA from "$app/components/server-components/DashboardSPA";
import { FeatureFlagsProvider } from "$app/components/FeatureFlags";

// Mock the feature flags context
const mockFeatureFlags = {
  require_email_typo_acknowledgment: false,
  dashboard_spa_enabled: true,
};

// Mock the current seller context
const mockCurrentSeller = {
  id: "123",
  name: "Test Creator",
  email: "test@example.com",
};

// Mock the logged in user context
const mockLoggedInUser = {
  id: "123",
  email: "test@example.com",
  helper_session: null,
};

// Mock the app domain context
const mockAppDomain = "app.gumroad.com";

// Mock the analytics function
jest.mock("$app/data/google_analytics", () => ({
  startTrackingForGumroad: jest.fn(),
}));

// Mock the Routes global
global.Routes = {
  settings_profile_path: () => "/settings/profile",
  logout_path: () => "/logout",
};

// Mock the gtag global
global.gtag = jest.fn();

const renderWithProviders = (component: React.ReactElement) => {
  return render(
    <FeatureFlagsProvider value={mockFeatureFlags}>
      <BrowserRouter>
        {component}
      </BrowserRouter>
    </FeatureFlagsProvider>
  );
};

describe("DashboardSPA", () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  it("renders the SPA when feature flag is enabled", () => {
    renderWithProviders(<DashboardSPA />);
    
    // Should render the dashboard layout
    expect(screen.getByText("Creator Dashboard")).toBeInTheDocument();
    
    // Should render navigation items
    expect(screen.getByText("Dashboard")).toBeInTheDocument();
    expect(screen.getByText("Products")).toBeInTheDocument();
    expect(screen.getByText("Sales")).toBeInTheDocument();
    expect(screen.getByText("Discover")).toBeInTheDocument();
    expect(screen.getByText("Library")).toBeInTheDocument();
  });

  it("shows fallback message when feature flag is disabled", () => {
    const disabledFeatureFlags = {
      ...mockFeatureFlags,
      dashboard_spa_enabled: false,
    };

    render(
      <FeatureFlagsProvider value={disabledFeatureFlags}>
        <BrowserRouter>
          <DashboardSPA />
        </BrowserRouter>
      </FeatureFlagsProvider>
    );

    expect(screen.getByText(/Dashboard SPA is currently disabled/)).toBeInTheDocument();
  });

  it("renders navigation with correct active states", () => {
    renderWithProviders(<DashboardSPA />);
    
    // Dashboard should be active by default
    const dashboardNav = screen.getByText("Dashboard").closest("a");
    expect(dashboardNav).toHaveAttribute("aria-current", "page");
  });

  it("renders footer navigation items", () => {
    renderWithProviders(<DashboardSPA />);
    
    expect(screen.getByText("Settings")).toBeInTheDocument();
    expect(screen.getByText("Logout")).toBeInTheDocument();
  });
});
