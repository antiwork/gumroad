# frozen_string_literal: true

require "benchmark"
require "timeout"

class Onetime::SetMaxAllowedRefundPeriodForPurchaseRefundPolicies < Onetime::Base
  LAST_PROCESSED_ID_KEY = :last_processed_id

  def self.reset_last_processed_id
    $redis.del(LAST_PROCESSED_ID_KEY)
  end

  def initialize(max_id: PurchaseRefundPolicy.last!.id)
    @max_id = max_id
    @title_cache = build_title_cache
    @link_cache = {}
  end

  def process
    invalid_policy_ids = []
    eligible_purchase_refund_policies.find_in_batches do |batch|
      ReplicaLagWatcher.watch
      Rails.logger.info "Processing purchase refund policies #{batch.first.id} to #{batch.last.id}"

      batch_stats = initialize_batch_stats
      batch_start_time = Time.now

      batch.each do |purchase_refund_policy|
        next if purchase_refund_policy.max_refund_period_in_days.present?

        record_timings = {}
        record_start_time = Time.now

        max_refund_period_in_days = determine_max_refund_period_in_days(purchase_refund_policy, record_timings)

        record_total_time = Time.now - record_start_time

        if max_refund_period_in_days.nil?
          log_policy_result(purchase_refund_policy.id, record_total_time, record_timings, "skipped - no match", nil)
          next
        end

        begin
          update_time = Benchmark.realtime do
            purchase_refund_policy.with_lock do
              purchase_refund_policy.update!(max_refund_period_in_days: max_refund_period_in_days)
            end
          end
          record_timings[:update] = update_time

          update_batch_stats(batch_stats, record_timings)
          log_policy_result(purchase_refund_policy.id, record_total_time, record_timings, "processed", max_refund_period_in_days)
          track_slowest_records(batch_stats, purchase_refund_policy.id, record_total_time)
          batch_stats[:processed_count] += 1
        rescue => e
          log_policy_result(purchase_refund_policy.id, record_total_time, record_timings, "error", nil, e.message)
          invalid_policy_ids << { purchase_refund_policy.id => e.message }
        end
      end

      batch_total_time = Time.now - batch_start_time
      log_batch_summary(batch_stats, batch_total_time)

      # Clear link cache periodically to prevent memory bloat
      @link_cache.clear if batch_stats[:processed_count] > 0

      $redis.set(LAST_PROCESSED_ID_KEY, batch.last.id, ex: 1.month)
    end

    Rails.logger.info "Invalid purchase refund policy ids: #{invalid_policy_ids}" if invalid_policy_ids.any?
  end

  private
    attr_reader :max_id, :title_cache, :link_cache

    def eligible_purchase_refund_policies
      first_policy_id = [first_eligible_policy_id, $redis.get(LAST_PROCESSED_ID_KEY).to_i + 1].max
      PurchaseRefundPolicy
        .where(id: first_policy_id..max_id)
        .includes({ purchase: { link: :product_refund_policy } })
        .preload(:purchase)
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

    def determine_max_refund_period_in_days(purchase_refund_policy, timings = {})
      previous_value = nil
      cache_time = Benchmark.realtime do
        previous_value = determine_max_refund_period_in_days_from_previous_policy(purchase_refund_policy)
      end
      timings[:cache_lookup] = cache_time

      return previous_value if previous_value.present?

      return 0 if purchase_refund_policy.title.match?(/no refunds|final|no returns/i)

      exact_match = nil
      exact_match_time = Benchmark.realtime do
        exact_match = find_exact_match_by_title(purchase_refund_policy.title)
      end
      timings[:exact_match] = exact_match_time

      return exact_match if exact_match

      begin
        ai_response = nil
        ai_time = Benchmark.realtime do
          ai_response = ask_ai_with_timeout(max_refund_period_in_days_prompt(purchase_refund_policy))
        end
        timings[:ai_call] = ai_time

        raw_content = ai_response.dig("choices", 0, "message", "content")
        days = Integer(raw_content) rescue raw_content

        if RefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS.key?(days)
          days
        else
          nil
        end
      rescue Net::ReadTimeout => e
        timings[:ai_error] = "timeout: #{e.message}"
        nil
      rescue OpenAI::Error => e
        error_details = extract_error_details(e)
        timings[:ai_error] = "openai: #{e.class.name} - #{e.message}#{error_details}"
        nil
      rescue Net::HTTPError => e
        error_details = extract_error_details(e)
        timings[:ai_error] = "http: #{e.class.name} - #{e.message}#{error_details}"
        nil
      rescue => e
        error_details = extract_error_details(e)
        timings[:ai_error] = "unexpected: #{e.class.name} - #{e.message}#{error_details}"
        nil
      end
    end

    def determine_max_refund_period_in_days_from_previous_policy(purchase_refund_policy)
      return nil unless purchase_refund_policy.purchase&.link&.product_refund_policy

      product_refund_policy = purchase_refund_policy.purchase.link.product_refund_policy
      return product_refund_policy.max_refund_period_in_days if product_refund_policy.read_attribute(:title) == purchase_refund_policy.title

      cached_value = title_cache[purchase_refund_policy.title]
      return cached_value if cached_value.present?

      # Use link cache to avoid repeated queries for the same link_id + title combination
      cache_key = "#{purchase_refund_policy.purchase.link_id}_#{purchase_refund_policy.title}"

      unless link_cache.key?(cache_key)
        other_purchase_refund_policy = PurchaseRefundPolicy
          .joins(:purchase)
          .where(purchases: { link_id: purchase_refund_policy.purchase.link_id })
          .where.not(id: purchase_refund_policy.id)
          .where(title: purchase_refund_policy.title)
          .select(:id, :max_refund_period_in_days)
          .limit(1)
          .first

        link_cache[cache_key] = other_purchase_refund_policy&.max_refund_period_in_days
      end

      return link_cache[cache_key] if link_cache[cache_key].present?

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
      request_params = {
        messages: [{ role: "user", content: prompt }],
        model: "gpt-4o-mini",
        temperature: 0.0,
        max_tokens: 10
      }

      OpenAI::Client.new.chat(parameters: request_params)
    end

    def ask_ai_with_timeout(prompt, timeout_seconds: 30)
      Timeout::timeout(timeout_seconds) do
        ask_ai(prompt)
      end
    rescue Timeout::Error
      raise Net::ReadTimeout, "AI request timed out after #{timeout_seconds} seconds"
    end

    def initialize_batch_stats
      {
        processed_count: 0,
        cache_lookups: { count: 0, total_time: 0.0 },
        exact_matches: { count: 0, total_time: 0.0 },
        ai_calls: { count: 0, total_time: 0.0 },
        updates: { count: 0, total_time: 0.0 },
        slowest_records: []
      }
    end

    def update_batch_stats(batch_stats, record_timings)
      if record_timings[:cache_lookup]
        batch_stats[:cache_lookups][:count] += 1
        batch_stats[:cache_lookups][:total_time] += record_timings[:cache_lookup]
      end

      if record_timings[:exact_match]
        batch_stats[:exact_matches][:count] += 1
        batch_stats[:exact_matches][:total_time] += record_timings[:exact_match]
      end

      if record_timings[:ai_call]
        batch_stats[:ai_calls][:count] += 1
        batch_stats[:ai_calls][:total_time] += record_timings[:ai_call]
      end

      if record_timings[:update]
        batch_stats[:updates][:count] += 1
        batch_stats[:updates][:total_time] += record_timings[:update]
      end
    end

    def log_policy_result(policy_id, total_time, timings, status, max_refund_days = nil, error_message = nil)
      timing_parts = []
      timing_parts << "cache: #{format_time(timings[:cache_lookup])}" if timings[:cache_lookup]
      timing_parts << "exact_match: #{format_time(timings[:exact_match])}" if timings[:exact_match]
      timing_parts << "ai: #{format_time(timings[:ai_call])}" if timings[:ai_call]
      timing_parts << "update: #{format_time(timings[:update])}" if timings[:update]
      timing_parts << "ai_error: #{timings[:ai_error]}" if timings[:ai_error]

      case status
      when "processed"
        Rails.logger.info "PurchaseRefundPolicy #{policy_id}: processed in #{format_time(total_time)} (#{timing_parts.join(', ')}) - set to #{max_refund_days} days"
      when "skipped - no match"
        Rails.logger.info "PurchaseRefundPolicy #{policy_id}: skipped in #{format_time(total_time)} (#{timing_parts.join(', ')}) - no match found"
      when "error"
        Rails.logger.info "PurchaseRefundPolicy #{policy_id}: error in #{format_time(total_time)} (#{timing_parts.join(', ')}) - #{error_message}"
      end
    end

    def track_slowest_records(batch_stats, policy_id, total_time)
      batch_stats[:slowest_records] << { id: policy_id, time: total_time }
      batch_stats[:slowest_records].sort_by! { |r| -r[:time] }
      batch_stats[:slowest_records] = batch_stats[:slowest_records].first(5)
    end

    def log_batch_summary(stats, total_time)
      return if stats[:processed_count].zero?

      avg_time = total_time / stats[:processed_count]
      Rails.logger.info "Batch summary: #{stats[:processed_count]} records in #{format_time(total_time)} (avg: #{format_time(avg_time)}/record)"

      if stats[:cache_lookups][:count] > 0
        avg_cache = stats[:cache_lookups][:total_time] / stats[:cache_lookups][:count]
        Rails.logger.info "  - Cache lookups: #{stats[:cache_lookups][:count]} (avg: #{format_time(avg_cache)})"
      end

      if stats[:exact_matches][:count] > 0
        avg_exact = stats[:exact_matches][:total_time] / stats[:exact_matches][:count]
        Rails.logger.info "  - Exact matches: #{stats[:exact_matches][:count]} (avg: #{format_time(avg_exact)})"
      end

      if stats[:ai_calls][:count] > 0
        avg_ai = stats[:ai_calls][:total_time] / stats[:ai_calls][:count]
        Rails.logger.info "  - AI calls: #{stats[:ai_calls][:count]} (avg: #{format_time(avg_ai)})"
      end

      if stats[:updates][:count] > 0
        avg_update = stats[:updates][:total_time] / stats[:updates][:count]
        Rails.logger.info "  - DB updates: #{stats[:updates][:count]} (avg: #{format_time(avg_update)})"
      end

      if stats[:slowest_records].any?
        slowest_list = stats[:slowest_records].map { |r| "#{r[:id]} (#{format_time(r[:time])})" }.join(", ")
        Rails.logger.info "Slowest records: [#{slowest_list}]"
      end
    end

    def format_time(seconds)
      return "0.000s" if seconds.nil?
      "#{format('%.3f', seconds)}s"
    end

    def extract_error_details(error)
      details = []

      if error.respond_to?(:response) && error.response
        if error.response.respond_to?(:body) && error.response.body
          body = error.response.body
          body = body.length > 200 ? "#{body[0..200]}..." : body
          details << " | response_body: #{body}"
        end

        if error.response.respond_to?(:status)
          details << " | status: #{error.response.status}"
        end
      end

      if error.respond_to?(:response) && error.response&.respond_to?(:status)
        details << " | http_status: #{error.response.status}"
      end

      if error.respond_to?(:cause) && error.cause
        details << " | cause: #{error.cause.class.name} - #{error.cause.message}"
      end

      if error.is_a?(Faraday::Error)
        details << " | faraday_error: #{error.class.name}"
        if error.respond_to?(:response) && error.response
          details << " | response_status: #{error.response.status}" if error.response.respond_to?(:status)
          details << " | response_headers: #{error.response.headers.inspect}" if error.response.respond_to?(:headers)
        end
      end

      if error.is_a?(Net::ReadTimeout) || error.message.include?("ReadTimeout")
        details << " | timeout_type: Net::ReadTimeout"
        details << " | socket_closed: #{error.message.include?('closed')}"
      end

      details.join
    end
end
