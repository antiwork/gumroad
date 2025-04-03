# frozen_string_literal: true

class UpdateTaxonomyStatsJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  def perform
    taxonomies = Taxonomy.roots

    taxonomies.each do |taxonomy|
      descendant_ids = taxonomy.descendant_ids
      stat = TaxonomyStat.find_or_create_by!(taxonomy:)
      shared_params = {
        taxonomy: [taxonomy.id] + descendant_ids,
        state: "successful",
        size: 0,
        exclude_unreversed_chargedback: true,
        exclude_refunded: true,
        exclude_bundle_product_purchases: true,
        track_total_hits: true,
      }

      search_result = PurchaseSearchService.search(
        **shared_params,
        aggs: {
          creators_count: { cardinality: { field: "seller_id" } },
          products_count: { cardinality: { field: "product_id" } },
        }
      ).response

      stat.sales_count = search_result["hits"]["total"]["value"]
      stat.creators_count = search_result.aggregations.creators_count.value
      stat.products_count = search_result.aggregations.products_count.value

      search_result = PurchaseSearchService.search(
        **shared_params,
        created_on_or_after: 30.days.ago,
      ).response
      stat.recent_sales_count = search_result["hits"]["total"]["value"]
      stat.save!
    end
  end
end
