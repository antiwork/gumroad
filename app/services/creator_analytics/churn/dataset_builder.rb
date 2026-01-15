# frozen_string_literal: true

# Assembles churn metrics from raw ES buckets: daily buckets, derived monthly rollups,
# and period summaries keyed by product. Subscriber bases are the period base
# (active-at-start + new) per bucket so the UI can re-aggregate by product without
# recomputing denominators. Relies on caller to provide ES-extracted counts.
class CreatorAnalytics::Churn::DatasetBuilder
  attr_reader :product_scope, :date_window, :churn_events, :new_subscriptions, :initial_active_counts

  def initialize(product_scope:, date_window:, churn_events:, new_subscriptions:, initial_active_counts:)
    @product_scope = product_scope
    @date_window = date_window
    @churn_events = churn_events
    @new_subscriptions = new_subscriptions
    @initial_active_counts = initial_active_counts
  end

  # Sample output:
  # {
  #   metadata: { timezone: "-07:00", products: [{ external_id: "123", name: "Alpha" }] },
  #   data: {
  #     daily: { "2024-05-01" => { total: { churn_rate: 1.0, subscriber_base: 100 } } },
  #     monthly: { "2024-05-01" => { total: { churn_rate: 1.5, subscriber_base: 300 } } },
  #     summary: {
  #       by_product: {
  #         "alpha" => { churn_rate: 1.0, churned_customers_count: 3, revenue_lost_cents: 15000, subscriber_base: 300 }
  #       },
  #       total: { churn_rate: 1.2, churned_customers_count: 10, revenue_lost_cents: 50000, subscriber_base: 820 },
  #     }
  #   }
  # }
  def build
    daily_data, monthly_inputs = build_daily_data

    {
      metadata: metadata_payload,
      data: {
        daily: daily_data,
        monthly: build_monthly_data(monthly_inputs),
        summary: summary_payload
      }
    }
  end

  private
    def metadata_payload
      {
        start_date: date_window.start_date.to_s,
        end_date: date_window.end_date.to_s,
        products: product_infos.values.map do |info|
          {
            external_id: info[:external_id],
            permalink: info[:permalink],
            name: info[:name]
          }
        end
      }
    end

    def product_infos
      @product_infos ||= product_scope.product_map
    end

    def build_daily_data
      running_active = Hash.new(0).merge(initial_active_counts)
      monthly_inputs = Hash.new { |hash, month_key| hash[month_key] = empty_month_entry }

      daily_results = {}

      date_window.daily_dates.each do |date|
        day_key = date.to_s
        month_key = Date.new(date.year, date.month, 1).to_s
        totals_tracker = { churned: 0, revenue: 0, denominator: 0 }

        daily_results[day_key] = { by_product: {}, total: zero_stat_hash }

        product_infos.each do |product_id, info|
          new_count = new_subscriptions.fetch([product_id, date], 0)
          churn_entry = churn_events.fetch([product_id, date], { churned_count: 0, revenue_lost_cents: 0 })
          churn_count = churn_entry[:churned_count]
          revenue = churn_entry[:revenue_lost_cents]

          active_base = running_active.fetch(product_id, 0)
          denominator = active_base + new_count
          churn_rate = compute_rate(churn_count, denominator)

          daily_results[day_key][:by_product][info[:permalink]] = {
            churn_rate: churn_rate,
            churned_customers_count: churn_count,
            revenue_lost_cents: revenue,
            subscriber_base: denominator
          }

          monthly_product_entry = monthly_inputs[month_key][:by_product][info[:permalink]]
          if monthly_product_entry[:active_start].nil?
            monthly_product_entry[:active_start] = active_base
            monthly_inputs[month_key][:total][:active_start] += active_base
          end

          monthly_product_entry[:new_subscriptions] += new_count
          monthly_inputs[month_key][:total][:new_subscriptions] += new_count

          totals_tracker[:churned] += churn_count
          totals_tracker[:revenue] += revenue
          totals_tracker[:denominator] += denominator

          monthly_product_entry[:churned] += churn_count
          monthly_product_entry[:revenue] += revenue

          running_active[product_id] = [active_base + new_count - churn_count, 0].max
        end

        denom = totals_tracker[:denominator]
        total_rate = compute_rate(totals_tracker[:churned], denom)
        daily_results[day_key][:total] = {
          churn_rate: total_rate,
          churned_customers_count: totals_tracker[:churned],
          revenue_lost_cents: totals_tracker[:revenue],
          subscriber_base: denom
        }

        monthly_inputs[month_key][:total][:churned] += totals_tracker[:churned]
        monthly_inputs[month_key][:total][:revenue] += totals_tracker[:revenue]
      end

      [daily_results, monthly_inputs]
    end

    def build_monthly_data(monthly_inputs)
      date_window.monthly_dates.each_with_object({}) do |month_date, result|
        month_key = month_date.to_s
        month_entry = monthly_inputs[month_key]
        result[month_key] = {
          by_product: build_monthly_products(month_entry[:by_product]),
          total: build_monthly_total(month_entry[:total])
        }
      end
    end

    def build_monthly_products(monthly_product_data)
      product_infos.values.each_with_object({}) do |info, result|
        per_product = monthly_product_data[info[:permalink]]
        churned = per_product[:churned]
        revenue = per_product[:revenue]
        active_start = per_product[:active_start] || 0
        denominator = active_start + per_product[:new_subscriptions]
        rate = compute_rate(churned, denominator)

        result[info[:permalink]] = {
          churn_rate: rate,
          churned_customers_count: churned,
          revenue_lost_cents: revenue,
          subscriber_base: denominator
        }
      end
    end

    def build_monthly_total(total_data)
      denominator = total_data[:active_start] + total_data[:new_subscriptions]
      rate = compute_rate(total_data[:churned], denominator)
      {
        churn_rate: rate,
        churned_customers_count: total_data[:churned],
        revenue_lost_cents: total_data[:revenue],
        subscriber_base: denominator
      }
    end

    def zero_stat_hash
      { churn_rate: 0.0, churned_customers_count: 0, revenue_lost_cents: 0, subscriber_base: 0 }
    end

    def summary_payload
      churned_by_product = Hash.new(0)
      revenue_by_product = Hash.new(0)
      new_by_product = Hash.new(0)

      churn_events.each do |(product_id, _date), entry|
        churned_by_product[product_id] += entry[:churned_count]
        revenue_by_product[product_id] += entry[:revenue_lost_cents]
      end

      new_subscriptions.each do |(product_id, _date), count|
        new_by_product[product_id] += count
      end

      totals = { churned: 0, revenue: 0, subscriber_base: 0 }

      by_product = product_infos.each_with_object({}) do |(product_id, info), result|
        churned = churned_by_product[product_id]
        revenue = revenue_by_product[product_id]
        new_count = new_by_product[product_id]
        starting_active = initial_active_counts.fetch(product_id, 0)
        denominator = starting_active + new_count
        churn_rate = compute_rate(churned, denominator)

        result[info[:permalink]] = {
          churn_rate: churn_rate,
          churned_customers_count: churned,
          revenue_lost_cents: revenue,
          subscriber_base: denominator
        }

        totals[:churned] += churned
        totals[:revenue] += revenue
        totals[:subscriber_base] += denominator
      end

      total_rate = compute_rate(totals[:churned], totals[:subscriber_base])

      {
        total: {
          churn_rate: total_rate,
          churned_customers_count: totals[:churned],
          revenue_lost_cents: totals[:revenue],
          subscriber_base: totals[:subscriber_base]
        },
        by_product: by_product
      }
    end

    def compute_rate(numerator, denominator)
      return 0.0 unless denominator.positive?
      ((numerator.to_f / denominator) * 100).round(2)
    end

    def empty_month_entry
      {
        by_product: Hash.new do |inner_hash, permalink|
          inner_hash[permalink] = { churned: 0, revenue: 0, active_start: nil, new_subscriptions: 0 }
        end,
        total: { churned: 0, revenue: 0, active_start: 0, new_subscriptions: 0 }
      }
    end
end
