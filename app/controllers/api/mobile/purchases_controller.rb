# frozen_string_literal: true

class Api::Mobile::PurchasesController < Api::Mobile::BaseController
  before_action { doorkeeper_authorize! :mobile_api }
  before_action :fetch_purchase, only: [:purchase_attributes, :archive, :unarchive]
  DEFAULT_SEARCH_RESULTS_SIZE = 10

  def index
    purchases = current_resource_owner.purchases.for_mobile_listing
    purchases_json = if params[:per_page] && params[:page]
      purchases_to_json(
        purchases.page_with_kaminari(params[:page]).per(params[:per_page])
      )
    else
      media_locations_scope = MediaLocation.where(product_id: purchases.pluck(:link_id))
      cache [purchases, media_locations_scope], expires_in: 10.minutes do
        purchases_to_json(purchases)
      rescue => e
        # Cache empty array for requests that timeout to reduce the load on database.
        # TODO: Remove this once we fix the bottleneck with the purchases_json generation
        Rails.logger.info "Error generating purchases json for user: #{current_resource_owner.id}, #{e.class} => #{e.message}"
        Bugsnag.notify(e)
        []
      end
    end

    render json: { success: true, products: purchases_json, user_id: current_resource_owner.external_id }
  end

  def search
    result = PurchaseSearchService.search(search_options)
    pagination = Pagy.new(count: result.response.hits.total.value, page: @page, limit: @items)

    render json: {
      success: true,
      user_id: current_resource_owner.external_id,
      purchases: purchases_to_json(result.records),
      sellers: formatted_sellers_agg(result.aggregations.seller_ids),
      meta: { pagination: PagyPresenter.new(pagination).metadata }
    }
  end

  def purchase_attributes
    render json: { success: true, product: @purchase.json_data_for_mobile }
  end

  def archive
    @purchase.is_archived = true
    @purchase.save!

    render json: {
      success: true,
      product: @purchase.json_data_for_mobile
    }
  end

  def unarchive
    @purchase.is_archived = false
    @purchase.save!

    render json: {
      success: true,
      product: @purchase.json_data_for_mobile
    }
  end

  private
    def fetch_purchase
      @purchase = current_resource_owner.purchases.find_by_external_id(params[:id])
      render json: { success: false, message: "Could not find purchase" }, status: :not_found if @purchase.nil? || (!@purchase.successful_and_not_reversed? && !@purchase.subscription)
    end

    def purchases_to_json(purchases)
      purchases.map(&:json_data_for_mobile)
    end

    def search_options
      @page = (params[:page] || 1).to_i
      @items = (params[:items] || DEFAULT_SEARCH_RESULTS_SIZE).to_i
      raise Pagy::VariableError.new(nil, :page, ">= 1", @page) if @page.zero? # manual validation
      sort = (Array.wrap(params[:order]).presence || ["score", "date-desc"]).map do |order_by|
        case order_by
        when "score" then :_score
        when "date-desc" then [{ created_at: :desc }, { id: :desc }]
        when "date-asc" then [{ created_at: :asc }, { id: :asc }]
        end
      end.flatten.compact

      options = {
        buyer_query: params[:q],
        purchaser: current_resource_owner,
        state: Purchase::ALL_SUCCESS_STATES,
        exclude_refunded_except_subscriptions: true,
        exclude_unreversed_chargedback: true,
        exclude_non_original_subscription_purchases: true,
        exclude_deactivated_subscriptions: true,
        exclude_bundle_product_purchases: true,
        exclude_commission_completion_purchases: true,
        track_total_hits: true,
        from: ((@page - 1) * @items),
        size: @items,
        sort:,
        aggs: {
          seller_ids: { terms: { field: "seller_id" } }
        }
      }

      options[:seller] = User.where(external_id: Array.wrap(params[:seller])) if params[:seller]
      options[:archived] = ActiveModel::Type::Boolean.new.cast(params[:archived]) if params[:archived]
      options
    end

    def formatted_sellers_agg(sellers_agg)
      buckets = sellers_agg.buckets
      sellers = User.where(id: buckets.pluck("key")).index_by(&:id)
      buckets.map do |bucket|
        seller = sellers.fetch(bucket["key"])
        {
          id: seller.external_id,
          name: seller.name,
          purchases_count: bucket["doc_count"]
        }
      end
    end
end
