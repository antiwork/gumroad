# frozen_string_literal: true

module SellerPlan
  # Bucketing for the paid-publish experiment. Assignment is a hash of the seller id, so a seller
  # always lands in the same arm, retries and devices included, and the split stays stable as the
  # rollout percentage grows.
  module Experiment
    FLAG = :seller_plan_gate

    CONTROL_SHARE = 50
    FIVE_SHARE = 25

    PRICE_CENTS = { "five" => 500, "ten" => 1000 }.freeze
    PRICE_CONFIG_KEYS = { "five" => "SELLER_PLAN_PRICE_5", "ten" => "SELLER_PLAN_PRICE_10" }.freeze

    def self.enabled_for?(user)
      return false if user.nil? || user.is_team_member?
      return false unless Feature.active?(FLAG, user)

      started_at = experiment_start
      started_at.present? && user.created_at >= started_at
    end

    def self.arm_for(user)
      bucket = Zlib.crc32("seller_plan:#{user.id}") % 100
      return "control" if bucket < CONTROL_SHARE
      return "five" if bucket < CONTROL_SHARE + FIVE_SHARE

      "ten"
    end

    # Nil when the Stripe price has not been created yet: an unconfigured arm must fall back to the
    # free flow rather than block a publish we have no way to charge for.
    def self.price_id(arm)
      GlobalConfig.get(PRICE_CONFIG_KEYS.fetch(arm)).presence
    end

    # The offer for this product's first publish, or nil when the seller is in the control arm,
    # outside the experiment, or has an active plan.
    def self.offer_for(link)
      user = link.user
      return nil unless link.draft? && enabled_for?(user)

      arm = arm_for(user)
      return nil if arm == "control"

      existing = SellerPlanOffer.find_by(user_id: user.id)
      return existing if existing&.active?
      return nil if price_id(arm).blank?

      existing || SellerPlanOffer.record_offer!(user:, link:, arm:, price_cents: PRICE_CENTS.fetch(arm))
    end

    def self.experiment_start
      raw = GlobalConfig.get("SELLER_PLAN_EXPERIMENT_START")
      return nil if raw.blank?

      Time.zone.parse(raw)
    rescue ArgumentError
      nil
    end

    private_class_method :experiment_start
  end
end
