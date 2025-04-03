# frozen_string_literal: true

class ProductRefundPolicy < RefundPolicy
  belongs_to :product, class_name: "Link"

  validates :title, presence: true, length: { maximum: 50 }
  validates :product, presence: true, uniqueness: true
  validate :product_must_belong_to_seller

  scope :for_visible_and_not_archived_products, -> { joins(:product).merge(Link.visible_and_not_archived) }

  def as_json(*)
    {
      fine_print:,
      id: external_id,
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
