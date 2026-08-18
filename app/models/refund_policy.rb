# frozen_string_literal: true

class RefundPolicy < ApplicationRecord
  include ExternalId

  has_paper_trail

  ALLOWED_REFUND_PERIODS_IN_DAYS = {
    0 => "No refunds allowed",
    7 => "7-day money back guarantee",
    14 => "14-day money back guarantee",
    30 => "30-day money back guarantee",
    183 => "6-month money back guarantee",
  }.freeze
  NO_REFUNDS_PERIOD_IN_DAYS = 0
  MINIMUM_DIGITAL_REFUND_PERIOD_IN_DAYS = 7
  DEFAULT_REFUND_PERIOD_IN_DAYS = 30

  attribute :max_refund_period_in_days, :integer, default: RefundPolicy::DEFAULT_REFUND_PERIOD_IN_DAYS

  belongs_to :seller, class_name: "User"

  stripped_fields :title, :fine_print, transform: -> { ActionController::Base.helpers.strip_tags(_1) }

  validates_presence_of :seller
  validates :fine_print, length: { maximum: 3_000 }

  validates :max_refund_period_in_days, inclusion: { in: ALLOWED_REFUND_PERIODS_IN_DAYS.keys }

  validate :fine_print_cannot_claim_no_refunds, if: -> { fine_print.present? && fine_print_changed? && !allows_no_refunds? }

  def self.periods_in_days(allow_no_refunds: false)
    keys = ALLOWED_REFUND_PERIODS_IN_DAYS.keys
    allow_no_refunds ? keys : keys.excluding(NO_REFUNDS_PERIOD_IN_DAYS)
  end

  def self.period_options(allow_no_refunds: false)
    periods_in_days(allow_no_refunds:).map do |days|
      { key: days, value: ALLOWED_REFUND_PERIODS_IN_DAYS[days] }
    end
  end

  def allows_no_refunds?
    false
  end

  # Account-level policies have no product. Pass for_physical: true when
  # snapshotting a physical purchase so a stored 0-day policy still applies.
  def effective_max_refund_period_in_days(for_physical: allows_no_refunds?)
    days = max_refund_period_in_days
    return days if days.blank? || for_physical

    [days, MINIMUM_DIGITAL_REFUND_PERIOD_IN_DAYS].max
  end

  def title
    ALLOWED_REFUND_PERIODS_IN_DAYS[effective_max_refund_period_in_days]
  end

  def as_json(*)
    {
      fine_print:,
      id: external_id,
      title:,
    }
  end

  # Fine print may condition refunds ("refunds only for duplicate purchases") but must not
  # deny them outright — that would contradict the guaranteed window. Fails open so an
  # OpenAI outage never blocks saves.
  def fine_print_claims_no_refunds?
    response = ask_ai(fine_print_no_refunds_prompt)
    JSON.parse(response.dig("choices", 0, "message", "content"))["no_refunds"]
  rescue => e
    Rails.logger.warn("Error moderating fine print for refund policy #{id}: #{e.message}")
    false
  end

  private
    def fine_print_cannot_claim_no_refunds
      return unless fine_print_claims_no_refunds?

      errors.add(:fine_print, "cannot state that refunds are not allowed")
    end

    def fine_print_no_refunds_prompt
      <<~PROMPT
        This refund policy guarantees buyers "#{title}". Return {"no_refunds": true} only if you
        are 100% confident the fine print asserts that refunds are never given at all (e.g.
        "no refunds", "all sales are final", "this product is non-refundable"), contradicting
        that guarantee. Fine print that only conditions or limits refunds (e.g. "no refunds
        after the refund window", "refunds only for duplicate purchases") is allowed: return
        {"no_refunds": false}.

        <refund policy fine print>
          #{fine_print}
        </refund policy fine print>
      PROMPT
    end

    def ask_ai(prompt)
      OpenAI::Client.new.chat(
        parameters: {
          messages: [{ role: "user", content: prompt }],
          model: "gpt-4o-mini",
          temperature: 0.0,
          max_tokens: 10
        }
      )
    end
end
