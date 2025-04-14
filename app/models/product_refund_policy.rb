# frozen_string_literal: true

class ProductRefundPolicy < RefundPolicy
  belongs_to :product, class_name: "Link"

  validates :product, presence: true, uniqueness: true
  validate :product_must_belong_to_seller

  scope :for_visible_and_not_archived_products, -> { joins(:product).merge(Link.visible_and_not_archived) }

  def as_json(*)
    {
      fine_print:,
      id: external_id,
      max_refund_period_in_days:,
      product_name: product.name,
      title:,
    }
  end

  def published_and_no_refunds?
    product.published? && no_refunds?
  end

  def no_refunds?
    return true if title.match?(/no refunds|final|no returns/i)

    response = ask_ai(no_refunds_prompt)
    value = JSON.parse(response.dig("choices", 0, "message", "content"))["no_refunds"]
    Rails.logger.debug("AI determined refund policy #{id} is no-refunds: #{value}")
    value
  rescue => e
    Rails.logger.debug("Error determining if refund policy #{id} is no-refunds: #{e.message}")
    false
  end

  def determine_max_refund_period_in_days
    return 0 if title.match?(/no refunds|final|no returns/i)

    begin
      response = ask_ai(max_refund_period_in_days_prompt)
      days = Integer(response.dig("choices", 0, "message", "content")) rescue response.dig("choices", 0, "message", "content")

      # Return only values from ALLOWED_REFUND_PERIODS_IN_DAYS or default to 30
      if RefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS.key?(days)
        days
      else
        Rails.logger.debug("Unknown refund period for policy #{id}: #{days}")
        RefundPolicy::DEFAULT_REFUND_PERIOD_IN_DAYS
      end
    rescue => e
      Rails.logger.debug("Error determining max refund period for policy #{id}: #{e.message}")
      RefundPolicy::DEFAULT_REFUND_PERIOD_IN_DAYS
    end
  end

  def max_refund_period_in_days_prompt
    prompt = <<~PROMPT
      You are an expert content reviewer that responds in numbers only.
      Your role is to determine the maximum number of days allowed for a refund policy based on the refund policy title.
      If the refund policy or fine print has words like "no refunds", "refunds not allowed", "no returns", "returns not allowed", "final" etc.), it's a no-refunds policy

      The allowed number of days are 0 (no refunds allowed), 7, 14, 30, or 183 (6 months). Use the number that most closely matches, but not above the maximum allowed.

      Example 1: If the title is "30-day money back guarantee", return 30.
      Example 2: If from the fine print it clearly states that there are no refunds, return 0.
      Example 3: If the analysis determines that it is a 3-day refund policy, return 3.
      Example 4: If the analysis determines that it is a 2-month refund policy, return 30.
      Example 5: If the analysis determines that it is a 1-year refund policy, return 183.
      Return one of the allowed numbers only if you are 100% confident. If you are not 100% confident, return -1.

      The response MUST be just a number. The only allowed numbers are: -1, 0, 7, 14, 30, 183.

      Product name: #{product.name}
      Product type: #{product.native_type}
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

  private
    def no_refunds_prompt
      prompt = <<~PROMPT
        Analyze this refund policy and return {"no_refunds": true} if you are 100% confident
        (has words like "no refunds", "refunds not allowed", "no returns", "returns not allowed", "final" etc.) it's a
        no-refunds policy, otherwise {"no_refunds": false}.

        Product name: #{product.name}
        Product type: #{product.native_type}
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

    def product_must_belong_to_seller
      return if seller.blank? || product.blank?
      return if seller == product.user

      errors.add(:product, :invalid)
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
