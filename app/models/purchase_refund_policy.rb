# frozen_string_literal: true

class PurchaseRefundPolicy < ApplicationRecord
  belongs_to :purchase, optional: true

  stripped_fields :title, :fine_print

  validates :purchase, presence: true, uniqueness: true
  validates :title, presence: true

  def different_than_product_refund_policy?
    title != product_refund_policy_title
  end

  def product_refund_policy_title
    purchase.link.product_refund_policy&.title
  end

  def determine_max_refund_period_in_days
    previous_value = determine_max_refund_period_in_days_from_previous_policy
    return previous_value if previous_value.present?

    return 0 if title.match?(/no refunds|final|no returns/i)

    exact_match = find_exact_match_by_title
    return exact_match if exact_match

    begin
      response = ask_ai(max_refund_period_in_days_prompt)
      days = Integer(response.dig("choices", 0, "message", "content")) rescue response.dig("choices", 0, "message", "content")

      # Return only values from ALLOWED_REFUND_PERIODS_IN_DAYS or nil for unmatched titles
      if RefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS.key?(days)
        days
      else
        Rails.logger.debug("Unknown refund period for policy #{id}: #{days}")
        nil
      end
    rescue => e
      Rails.logger.debug("Error determining max refund period for policy #{id}: #{e.message}")
      nil
    end
  end

  def max_refund_period_in_days_prompt
    prompt = <<~PROMPT
      You are an expert content reviewer that responds in numbers only.
      Your role is to determine the maximum number of days allowed for a refund policy based on the refund policy title & fine print.
      If the refund policy or fine print has words like "no refunds", "refunds not allowed", "no returns", "returns not allowed", "final" etc.), it's a no-refunds policy.

      The allowed number of days are 0 (no refunds allowed), 7, 14, 30, or 183 (6 months).
      Determine the number of days that match EXACTLY what the current refund policy mentions.

      Example 1: If the title is "30-day money back guarantee", return 30.
      Example 2: If from the fine print it clearly states that there are no refunds, return 0.
      Example 3: If the analysis determines that it is a 7-day refund policy, return 7.
      Example 4: If the analysis determines that it is a 2-month refund policy, return -1.
      Example 5: If the analysis determines that it is a 1-year refund policy, return -1.
      Return one of the allowed numbers only if you are 100% confident. If you are not 100% confident, return -1.

      The response MUST be just a number. The only allowed numbers are: -1, 0, 7, 14, 30, 183.

      Purchase ID: #{purchase.id}
      Refund policy title: #{title}
    PROMPT

    if fine_print.present?
      prompt += <<~FINE_PRINT
        <refund policy fine print>
          #{fine_print.truncate(300)}
        </refund policy fine print>
      FINE_PRINT
    end

    prompt
  end

  # Avoid calling AI if possible by checking the product refund policy, and previous purchase refund policies
  def determine_max_refund_period_in_days_from_previous_policy
    product_refund_policy = purchase.link.product_refund_policy
    return product_refund_policy.max_refund_period_in_days if product_refund_policy&.title == title

    other_purchase_refund_policy = PurchaseRefundPolicy.joins(:purchase).where(purchases: { link_id: purchase.link_id }).where.not(id: id).where(title:).first
    return other_purchase_refund_policy.max_refund_period_in_days if other_purchase_refund_policy.present?

    nil
  end

  private
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

  private
    def find_exact_match_by_title
      RefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS.each do |days, policy_title|
        return days if title.downcase.strip == policy_title.downcase.strip
      end
      nil
    end
end
