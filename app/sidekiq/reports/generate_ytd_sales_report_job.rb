# frozen_string_literal: true

module Reports
  class GenerateYtdSalesReportJob
    include Sidekiq::Worker
    sidekiq_options queue: "low", retry: 3

    def perform
      current_year_start = Time.current.beginning_of_year.iso8601

      es_query = {
        size: 0,
        query: {
          bool: {
            filter: [
              { range: { created_at: { gte: current_year_start, lte: "now" } } },
              { term: { not_chargedback_or_chargedback_reversed: true } },
              { terms: { purchase_state: [
                "successful",
                "preorder_concluded_successfully",
                "gift_receiver_purchase_successful",
                "pending_fulfillment",
                "refunded",
                "partially_refunded"
              ] } }
            ]
          }
        },
        aggs: {
          sales_by_country: {
            terms: {
              field: "country_or_ip_country",
              size: 250,
              missing: "UNKNOWN_COUNTRY"
            },
            aggs: {
              sales_by_state: {
                terms: {
                  field: "ip_state",
                  size: 100,
                  missing: "UNKNOWN_STATE"
                },
                aggs: {
                  total_gross_revenue_cents: { sum: { field: "price_cents" } },
                  total_refunded_cents: { sum: { field: "amount_refunded_cents" } },
                  net_sales_cents: {
                    bucket_script: {
                      buckets_path: {
                        gross_revenue: "total_gross_revenue_cents",
                        refunds: "total_refunded_cents"
                      },
                      script: "params.gross_revenue - params.refunds"
                    }
                  }
                }
              }
            }
          }
        }
      }

      results = Purchase.search(es_query)
      aggregations = results.aggregations

      csv_string = CsvSafe.generate do |csv|
        csv << ["Country", "State", "Net Sales (USD)"]

        if aggregations && aggregations["sales_by_country"] && aggregations["sales_by_country"]["buckets"]
          aggregations["sales_by_country"]["buckets"].each do |country_bucket|
            country_code = country_bucket["key"]
            if country_bucket["sales_by_state"] && country_bucket["sales_by_state"]["buckets"]
              country_bucket["sales_by_state"]["buckets"].each do |state_bucket|
                state_code = state_bucket["key"]
                net_sales_in_cents = state_bucket["net_sales_cents"] ? state_bucket["net_sales_cents"]["value"] : 0.0

                if state_bucket["doc_count"] > 0
                  csv << [country_code, state_code, (net_sales_in_cents.to_f / 100.0).round(2)]
                end
              end
            end
          end
        else
          Rails.logger.warn "Reports::GenerateYtdSalesReportJob: No aggregations found or structure not as expected. Check Elasticsearch results."
        end
      end

      recipient_emails = $redis.lrange(RedisKey.ytd_sales_report_emails, 0, -1)
      if recipient_emails.present?
        recipient_emails.each do |email|
          AccountingMailer.ytd_sales_report(csv_string, email.strip).deliver_now
          Rails.logger.info "Reports::GenerateYtdSalesReportJob: YTD Sales report sent to #{email.strip}"
        end
      else
        Rails.logger.warn "Reports::GenerateYtdSalesReportJob: No recipient emails found in Redis list '#{RedisKey.ytd_sales_report_emails}'. Report not sent."
      end
    end
  end
end
