# frozen_string_literal: true

module Product::CreationLimit
  extend ActiveSupport::Concern

  included do
    validate :validate_daily_product_creation_limit, on: :create
  end

  class_methods do
    def bypass_product_creation_limit
      previous = product_creation_limit_bypassed?
      self.product_creation_limit_bypassed = true
      yield
    ensure
      self.product_creation_limit_bypassed = previous
    end

    def product_creation_limit_bypassed?
      ActiveSupport::IsolatedExecutionState[ISOLATED_EXECUTION_STATE_KEY]
    end

    private
      def product_creation_limit_bypassed=(value)
        ActiveSupport::IsolatedExecutionState[ISOLATED_EXECUTION_STATE_KEY] = value
      end
  end

  private
    ISOLATED_EXECUTION_STATE_KEY = :gumroad_bypass_product_creation_limit

    def validate_daily_product_creation_limit
      return if skip_daily_product_creation_limit?

      last_24h_links_count = user.links.where(created_at: 1.day.ago..).count
      return if last_24h_links_count < daily_creation_limit

      errors.add(:base, "Sorry, you can only create #{daily_creation_limit} products per day.")
    end

    def skip_daily_product_creation_limit?
      return true if Rails.env.development?
      return true if self.class.product_creation_limit_bypassed?
      return true if user.blank?
      return true if user.is_team_member?

      false
    end

    def daily_creation_limit
      user&.compliant? ? 100 : 10
    end
end
