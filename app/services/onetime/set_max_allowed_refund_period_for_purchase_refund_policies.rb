# frozen_string_literal: true

class Onetime::SetMaxAllowedRefundPeriodForPurchaseRefundPolicies < Onetime::Base
  LAST_PROCESSED_ID_KEY = :last_processed_id

  def self.reset_last_processed_id
    $redis.del(LAST_PROCESSED_ID_KEY)
  end

  def initialize(max_id: PurchaseRefundPolicy.last!.id)
    @max_id = max_id
    @title_cache = build_title_cache
  end

  def process
    invalid_policy_ids = []
    eligible_purchase_refund_policies.find_in_batches do |batch|
      ReplicaLagWatcher.watch
      Rails.logger.info "Processing purchase refund policies #{batch.first.id} to #{batch.last.id}"

      batch.each do |purchase_refund_policy|
        next if purchase_refund_policy.max_refund_period_in_days.present?

        max_refund_period_in_days = determine_max_refund_period_in_days(purchase_refund_policy)
        if max_refund_period_in_days.nil?
          Rails.logger.info("No exact match found for title '#{purchase_refund_policy.title}', skipping")
          next
        end

        begin
          purchase_refund_policy.with_lock do
            purchase_refund_policy.update!(max_refund_period_in_days: max_refund_period_in_days)
            Rails.logger.info "PurchaseRefundPolicy: #{purchase_refund_policy.id}: updated with max allowed refund period of #{max_refund_period_in_days} days"
          end
        rescue => e
          invalid_policy_ids << { purchase_refund_policy.id => e.message }
        end
      end

      $redis.set(LAST_PROCESSED_ID_KEY, batch.last.id, ex: 1.month)
    end

    Rails.logger.info "Invalid purchase refund policy ids: #{invalid_policy_ids}" if invalid_policy_ids.any?
  end

  private
    attr_reader :max_id, :title_cache

    def eligible_purchase_refund_policies
      first_policy_id = [first_eligible_policy_id, $redis.get(LAST_PROCESSED_ID_KEY).to_i + 1].max
      PurchaseRefundPolicy
        .where(id: first_policy_id..max_id)
        .includes({ purchase: :link }, :product_refund_policy)
    end

    def first_eligible_policy_id
      PurchaseRefundPolicy.first!.id
    end

    def build_title_cache
      Rails.logger.info "Building title cache..."
      cache = PurchaseRefundPolicy
        .where.not(max_refund_period_in_days: nil)
        .distinct
        .pluck(:title, :max_refund_period_in_days)
        .to_h
      Rails.logger.info "Title cache built with #{cache.size} unique titles"
      cache
    end

    def determine_max_refund_period_in_days(purchase_refund_policy)
      previous_value = determine_max_refund_period_in_days_from_previous_policy(purchase_refund_policy)
      return previous_value if previous_value.present?

      return 0 if purchase_refund_policy.title.match?(/no refunds|final|no returns/i)

      exact_match = find_exact_match_by_title(purchase_refund_policy.title)
      return exact_match if exact_match

      begin
        response = ask_ai(max_refund_period_in_days_prompt(purchase_refund_policy))
        days = Integer(response.dig("choices", 0, "message", "content")) rescue response.dig("choices", 0, "message", "content")

        if RefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS.key?(days)
          days
        else
          Rails.logger.info("  #{purchase_refund_policy.id}: Unknown refund period for policy : #{days}")
          nil
        end
      rescue => e
        Rails.logger.info("  #{purchase_refund_policy.id}: Error determining max refund period for policy: #{e.message}")
        nil
      end
    end

    def determine_max_refund_period_in_days_from_previous_policy(purchase_refund_policy)
      return purchase_refund_policy.product_refund_policy.max_refund_period_in_days if purchase_refund_policy.product_refund_policy&.title == purchase_refund_policy.title

      cached_value = title_cache[purchase_refund_policy.title]
      return cached_value if cached_value.present?

      other_purchase_refund_policy = PurchaseRefundPolicy.joins(:purchase).where(purchases: { link_id: purchase_refund_policy.purchase.link_id }).where.not(id: purchase_refund_policy.id).where(title: purchase_refund_policy.title).first
      return other_purchase_refund_policy.max_refund_period_in_days if other_purchase_refund_policy.present?

      nil
    end

    def find_exact_match_by_title(title)
      RefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS.each do |days, policy_title|
        return days if title.downcase.strip == policy_title.downcase.strip
      end
      nil
    end

    def max_refund_period_in_days_prompt(purchase_refund_policy)
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

        Purchase ID: #{purchase_refund_policy.purchase.id}
        Refund policy title: #{purchase_refund_policy.title}
      PROMPT

      if purchase_refund_policy.fine_print.present?
        prompt += <<~FINE_PRINT
          <refund policy fine print>
            #{purchase_refund_policy.fine_print.truncate(300)}
          </refund policy fine print>
        FINE_PRINT
      end

      prompt
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
