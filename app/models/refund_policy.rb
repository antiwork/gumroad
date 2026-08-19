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
  DEFAULT_REFUND_PERIOD_IN_DAYS = 30

  attribute :max_refund_period_in_days, :integer, default: RefundPolicy::DEFAULT_REFUND_PERIOD_IN_DAYS

  belongs_to :seller, class_name: "User"

  stripped_fields :title, :fine_print, transform: -> { ActionController::Base.helpers.strip_tags(_1) }

  validates_presence_of :seller
  validates :fine_print, length: { maximum: 3_000 }

  validates :max_refund_period_in_days, inclusion: { in: ALLOWED_REFUND_PERIODS_IN_DAYS.keys }

  # Skip when the selected window is already "No refunds allowed" — the title
  # matches. A positive window plus "all sales are final" is the contradiction.
  validate :fine_print_cannot_claim_no_refunds, if: -> { fine_print.present? && fine_print_changed? && refunds_guaranteed? }

  def title
    ALLOWED_REFUND_PERIODS_IN_DAYS[max_refund_period_in_days]
  end

  def as_json(*)
    {
      fine_print:,
      id: external_id,
      title:,
    }
  end

  # Fails open so an OpenAI outage never blocks saves.
  def fine_print_claims_no_refunds?
    response = ask_ai(fine_print_no_refunds_prompt)
    JSON.parse(response.dig("choices", 0, "message", "content"))["no_refunds"]
  rescue => e
    Rails.logger.warn("Error moderating fine print for refund policy #{id}: #{e.message}")
    false
  end

  private
    def refunds_guaranteed?
      max_refund_period_in_days.to_i.positive?
    end

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
