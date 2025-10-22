# frozen_string_literal: true

class Onetime::BackfillInstallmentTotalPrices < Onetime::Base
  attr_reader :dry_run, :batch_size, :stats

  def initialize(dry_run: true, batch_size: 1000)
    @dry_run = dry_run
    @batch_size = batch_size
    @stats = {
      total_processed: 0,
      backfilled_strategy_1: 0,
      backfilled_strategy_2: 0,
      skipped_no_payments: 0,
      skipped_plan_changed: 0,
      skipped_price_changed: 0,
      skipped_invalid_remainder: 0,
      skipped_other: 0,
      errors: 0
    }
  end

  def process
    log_start

    eligible_subscriptions.find_each(batch_size: batch_size) do |subscription|
      process_subscription(subscription)
      log_progress if (@stats[:total_processed] % 100).zero?
    end

    log_summary
  end

  private
    def eligible_subscriptions
      Subscription
        .active
        .joins(:original_purchase)
        .where("subscriptions.flags & ? > 0", Subscription.flag_mapping["flags"][:is_installment_plan])
        .where("json_extract(purchases.json_data, '$.total_price_before_installments_cents') IS NULL")
        .includes(:payment_options, :original_purchase, :link)
    end

    def process_subscription(subscription)
      @stats[:total_processed] += 1

      result = derive_total_from_purchases(subscription)

      if result[:total].present?
        backfill_subscription(subscription, result)
      else
        skip_subscription(subscription, result)
      end
    rescue StandardError => e
      log_error(subscription, e)
      @stats[:errors] += 1
    end

    def derive_total_from_purchases(subscription)
      strategy_1_result = attempt_strategy_1(subscription)
      return strategy_1_result if strategy_1_result[:total].present?
      attempt_strategy_2(subscription)
    end

    def attempt_strategy_1(subscription)
      purchases = subscription.purchases.successful.order(:created_at).limit(2)

      if purchases.size < 2
        return { total: nil, strategy: 1, reason: "Only #{purchases.size} payment(s) made" }
      end

      first_payment = purchases.first.displayed_price_cents
      second_payment = purchases.second.displayed_price_cents

      plan = subscription.payment_options.first&.installment_plan
      unless plan
        return { total: nil, strategy: 1, reason: "No installment plan found in payment_option" }
      end

      count = plan.number_of_installments
      remainder = first_payment - second_payment

      if remainder < 0 || remainder >= count
        return {
          total: nil,
          strategy: 1,
          reason: "Invalid remainder #{remainder} (must be 0 <= remainder < #{count})",
          first_payment: first_payment,
          second_payment: second_payment,
          count: count
        }
      end

      total = second_payment * count + remainder

      {
        total: total,
        strategy: 1,
        first_payment: first_payment,
        second_payment: second_payment,
        count: count,
        remainder: remainder
      }
    end

    def attempt_strategy_2(subscription)
      purchases = subscription.purchases.successful.order(:created_at).limit(2)

      if purchases.size != 1
        return { total: nil, strategy: 2, reason: "Expected 1 payment, found #{purchases.size}" }
      end

      plan = subscription.payment_options.first&.installment_plan
      unless plan
        return { total: nil, strategy: 2, reason: "No installment plan found in payment_option" }
      end

      current_product_plan = subscription.link.installment_plan
      unless current_product_plan
        return { total: nil, strategy: 2, reason: "Product no longer has installment plan" }
      end

      if plan.id != current_product_plan.id
        return {
          total: nil,
          strategy: 2,
          reason: "Plan changed (original: #{plan.id}, current: #{current_product_plan.id})"
        }
      end

      if plan.number_of_installments != current_product_plan.number_of_installments
        return {
          total: nil,
          strategy: 2,
          reason: "Installment count changed (was #{plan.number_of_installments}, now #{current_product_plan.number_of_installments})"
        }
      end

      first_payment = purchases.first.displayed_price_cents
      current_price = subscription.link.price_cents

      # Calculate expected payments using current price to detect price changes
      expected_payments = plan.calculate_installment_payment_price_cents(current_price)
      expected_second = expected_payments[1] || expected_payments[0]

      remainder = first_payment - expected_second
      count = plan.number_of_installments

      # If remainder is invalid, check if it's due to price change
      # A large negative remainder often indicates price increased significantly
      if remainder < 0 || remainder >= count
        # Estimate original price from first payment to detect price changes
        # First payment is approximately total_price / count + remainder
        # So total_price is approximately first_payment * count
        estimated_original_total = first_payment * count

        # If the remainder is very negative or the estimated total is very different from current price,
        # it likely means the price changed
        price_difference = (estimated_original_total - current_price).abs
        if remainder < -100 || price_difference > (current_price * 0.1)
          return {
            total: nil,
            strategy: 2,
            reason: "Price changed (estimated original: ~#{estimated_original_total}, current: #{current_price}, remainder: #{remainder})"
          }
        end

        return {
          total: nil,
          strategy: 2,
          reason: "Invalid remainder #{remainder} (must be 0 <= remainder < #{count})",
          first_payment: first_payment,
          expected_second: expected_second,
          count: count
        }
      end

      # Calculate total from valid remainder and verify it matches current price
      total = expected_second * count + remainder

      # For installment plans, total should equal product price
      # If they don't match, price may have changed
      if total != current_price
        return {
          total: nil,
          strategy: 2,
          reason: "Price changed (calculated total: #{total}, current: #{current_price})"
        }
      end

      {
        total: total,
        strategy: 2,
        first_payment: first_payment,
        expected_second: expected_second,
        count: count,
        remainder: remainder,
        warning: "Strategy 2 used - assumes no price/plan changes"
      }
    end

    def backfill_subscription(subscription, result)
      if dry_run
        log_backfill_dry_run(subscription, result)
      else
        ActiveRecord::Base.transaction do
          subscription.original_purchase.update!(total_price_before_installments_cents: result[:total])
        end
        log_backfill_success(subscription, result)
      end

      if result[:strategy] == 1
        @stats[:backfilled_strategy_1] += 1
      else
        @stats[:backfilled_strategy_2] += 1
      end
    end

    def skip_subscription(subscription, result)
      log_skip(subscription, result)

      case result[:reason]
      when /Only.*payment/
        @stats[:skipped_no_payments] += 1
      when /Plan changed/
        @stats[:skipped_plan_changed] += 1
      when /Price changed/
        @stats[:skipped_price_changed] += 1
      when /Invalid remainder/
        @stats[:skipped_invalid_remainder] += 1
      else
        @stats[:skipped_other] += 1
      end
    end

    def log_start
      mode = dry_run ? "DRY RUN" : "LIVE"
      Rails.logger.info("[Backfill #{mode}] Starting backfill of installment total prices...")
      Rails.logger.info("[Backfill #{mode}] Processing subscriptions in batches of #{batch_size}")
    end

    def log_progress
      Rails.logger.info("[Backfill] Progress: #{@stats[:total_processed]} subscriptions processed...")
    end

    def log_backfill_dry_run(subscription, result)
      strategy = result[:strategy]
      Rails.logger.info("✅ [DRY RUN] Subscription #{subscription.external_id} (ID: #{subscription.id}): Would backfill via Strategy #{strategy}")
      log_calculation_details(result)
    end

    def log_backfill_success(subscription, result)
      strategy = result[:strategy]
      Rails.logger.info("✅ Subscription #{subscription.external_id} (ID: #{subscription.id}): Backfilled via Strategy #{strategy}")
      log_calculation_details(result)
      Rails.logger.warn("   ⚠️  #{result[:warning]}") if result[:warning]
    end

    def log_calculation_details(result)
      if result[:strategy] == 1
        Rails.logger.info("   First payment: #{result[:first_payment]} cents, Second payment: #{result[:second_payment]} cents, Installments: #{result[:count]}")
        Rails.logger.info("   Calculated total: #{result[:total]} cents")
      else
        Rails.logger.info("   First payment: #{result[:first_payment]} cents, Expected second: #{result[:expected_second]} cents, Installments: #{result[:count]}")
        Rails.logger.info("   Calculated total: #{result[:total]} cents")
      end
    end

    def log_skip(subscription, result)
      Rails.logger.warn("⚠️  Subscription #{subscription.external_id} (ID: #{subscription.id}): SKIPPED")
      Rails.logger.warn("   Strategy #{result[:strategy]}: FAILED - #{result[:reason]}")
      Rails.logger.warn("   → Manual review required")
    end

    def log_error(subscription, error)
      Rails.logger.error("❌ Subscription #{subscription.external_id} (ID: #{subscription.id}): ERROR")
      Rails.logger.error("   #{error.class}: #{error.message}")
      Rails.logger.error(error.backtrace.first(5).join("\n   "))
    end

    def log_summary
      mode = dry_run ? "DRY RUN" : "LIVE"
      Rails.logger.info("\n[Backfill #{mode}] Summary:")
      Rails.logger.info("- Total processed: #{@stats[:total_processed]}")
      Rails.logger.info("- Backfilled via Strategy 1: #{@stats[:backfilled_strategy_1]}")
      Rails.logger.info("- Backfilled via Strategy 2: #{@stats[:backfilled_strategy_2]}")
      Rails.logger.info("- Skipped (no/insufficient payments): #{@stats[:skipped_no_payments]}")
      Rails.logger.info("- Skipped (plan changed): #{@stats[:skipped_plan_changed]}")
      Rails.logger.info("- Skipped (price changed): #{@stats[:skipped_price_changed]}")
      Rails.logger.info("- Skipped (invalid remainder): #{@stats[:skipped_invalid_remainder]}")
      Rails.logger.info("- Skipped (other): #{@stats[:skipped_other]}")
      Rails.logger.info("- Errors: #{@stats[:errors]}")

      total_backfilled = @stats[:backfilled_strategy_1] + @stats[:backfilled_strategy_2]

      if @stats[:total_processed] > 0
        coverage = (total_backfilled.to_f / @stats[:total_processed] * 100).round(2)
        Rails.logger.info("\nCoverage: #{coverage}% (#{total_backfilled}/#{@stats[:total_processed]})")
      end
    end
end
