# frozen_string_literal: true

class DashboardSpaFeature
  # Feature flag for Dashboard SPA rollout
  FEATURE_FLAG_KEY = 'dashboard_spa_enabled'
  
  class << self
    # Check if user should see SPA version
    def should_redirect_to_spa?(user)
      return true if force_enabled?
      return false unless user
      
      # Gradual rollout logic
      enabled_for_user?(user) || enabled_globally?
    end

    # Force enable for testing/development
    def force_enabled?
      Rails.env.development? && ENV['DASHBOARD_SPA_FORCE_ENABLED'] == 'true'
    end

    # Check if SPA is enabled for specific user
    def enabled_for_user?(user)
      return false unless user
      
      # Enable for specific user IDs for testing
      test_user_ids = ENV['DASHBOARD_SPA_TEST_USERS']&.split(',')&.map(&:to_i) || []
      return true if test_user_ids.include?(user.id)
      
      # Enable based on user percentage rollout
      rollout_percentage = ENV['DASHBOARD_SPA_ROLLOUT_PERCENTAGE']&.to_i || 0
      return false if rollout_percentage <= 0
      
      # Use deterministic hash for consistent experience
      user_hash = Digest::MD5.hexdigest("#{user.id}-dashboard-spa").to_i(16)
      (user_hash % 100) < rollout_percentage
    end

    # Check if SPA is globally enabled
    def enabled_globally?
      ENV['DASHBOARD_SPA_ENABLED'] == 'true'
    end

    # Check if user is explicitly opted in
    def user_opted_in?(user)
      # This could be a user preference in the future
      false
    end

    # Admin override for specific user
    def force_enabled_for_user?(user)
      return false unless user
      
      # Could be extended to check admin settings per user
      false
    end
  end
end