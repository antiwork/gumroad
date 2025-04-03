# frozen_string_literal: true

module DashboardPreference
  COOKIE_NAME = "last_viewed_dashboard"
  SALES_DASHBOARD = "sales"
  AUDIENCE_DASHBOARD = "audience"
  private_constant :COOKIE_NAME, :SALES_DASHBOARD, :AUDIENCE_DASHBOARD

  private
    def preferred_dashboard_url
      return @_preferred_dashboard_url if defined?(@_preferred_dashboard_url)

      return unless cookies.key?(COOKIE_NAME)

      @_preferred_dashboard_url = cookies[COOKIE_NAME] == SALES_DASHBOARD ? sales_dashboard_url : audience_dashboard_url
    end

    def set_dashboard_preference_to_audience
      cookies[COOKIE_NAME] = AUDIENCE_DASHBOARD
    end

    def set_dashboard_preference_to_sales
      cookies[COOKIE_NAME] = SALES_DASHBOARD
    end

    def clear_dashboard_preference
      cookies.delete(COOKIE_NAME)
    end
end
