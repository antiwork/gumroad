# frozen_string_literal: true

module Product::CreationLimit
  extend ActiveSupport::Concern

  included do
    validate :validate_daily_product_creation_limit, on: :create
  end

  private
    DAILY_CREATION_LIMIT = 10

    def validate_daily_product_creation_limit
      return if skip_daily_product_creation_limit?

      last_24h_links_count = user.links.where(created_at: 1.day.ago..).count
      return if last_24h_links_count < DAILY_CREATION_LIMIT

      errors.add(:base, "Sorry, you can only create #{DAILY_CREATION_LIMIT} products per day.")
    end

    def skip_daily_product_creation_limit?
      return true if user.blank?
      return true if user.is_team_member?

      false
    end
end
