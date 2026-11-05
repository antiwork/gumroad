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

      # Deleting a product frees up quota (Sahil, 2026-08-08: accepted the delete-and-recreate
      # abuse-risk tradeoff explicitly -- the anti-spam property this limit had is intentionally
      # weakened in exchange for not permanently losing a seller's work when they delete a product
      # thinking it was a "test" or duplicate). Still counts real accounts creating >daily_creation_limit
      # products currently alive in the rolling 24h window.
      created_ats = user.links.where(created_at: 1.day.ago.., deleted_at: nil).order(:created_at).pluck(:created_at)
      limit = daily_creation_limit
      return if created_ats.size < limit

      message = "Sorry, you can only create #{limit} products per day."
      # A zero quota frees no slot, so there is no reset time to name.
      if limit.positive?
        next_slot_at = created_ats[created_ats.size - limit] + 1.day
        message += " You can create another product after #{format_next_slot(next_slot_at)}."
      end
      errors.add(:base, message)
    end

    def format_next_slot(time)
      # Round up: the message names whole minutes, and the slot is still taken until the exact second passes.
      time = time.change(sec: 0) + 1.minute unless time == time.change(sec: 0)
      zone = ActiveSupport::TimeZone[user.timezone.to_s] || Time.zone
      time.in_time_zone(zone).strftime("%B %-d at %-l:%M %p %Z")
    end

    def skip_daily_product_creation_limit?
      return true if Rails.env.development?
      return true if self.class.product_creation_limit_bypassed?
      return true if user.blank?
      return true if user.is_team_member?

      false
    end

    def daily_creation_limit
      user&.daily_product_creation_limit || default_daily_creation_limit
    end

    def default_daily_creation_limit
      user&.compliant? ? 100 : 10
    end
end
