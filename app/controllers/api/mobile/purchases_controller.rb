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
        ErrorNotifier.notify(e)
        []
      end
    end

    render json: { success: true, products: purchases_json, user_id: current_resource_owner.external_id }
  end

  def search
    purchases = search_purchases
    page = (params[:page] || 1).to_i
    items = (params[:items] || DEFAULT_SEARCH_RESULTS_SIZE).to_i

    pagination = Pagy.new(count: purchases.count(:all), page: page, limit: items)
    paginated_purchases = purchases.offset((page - 1) * items).limit(items)

    render json: {
      success: true,
      user_id: current_resource_owner.external_id,
      purchases: purchases_to_json(paginated_purchases),
      sellers: sellers_from_purchases(purchases),
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

    def search_purchases
      purchases = current_resource_owner.purchases.for_mobile_listing.joins(:link, :seller)

      if params[:q].present?
        query = "%#{ActiveRecord::Base.sanitize_sql_like(params[:q])}%"
        purchases = purchases.where("links.name LIKE :q OR users.name LIKE :q", q: query)
      end

      if params[:seller].present?
        purchases = purchases.where(seller_id: User.where(external_id: Array.wrap(params[:seller])).select(:id))
      end

      if params[:archived].present?
        archived = ActiveModel::Type::Boolean.new.cast(params[:archived])
        purchases = archived ? purchases.is_archived : purchases.not_is_archived
      end

      if params[:purchase_ids].present?
        purchase_ids = Array.wrap(params[:purchase_ids]).filter_map { |id| ObfuscateIds.decrypt(id) }
        purchases = purchases.where(id: purchase_ids.presence || [0])
      end

      case params[:order] || "date-desc"
      when "date-desc" then purchases = purchases.reorder(created_at: :desc, id: :desc)
      when "date-asc" then purchases = purchases.reorder(created_at: :asc, id: :asc)
      end

      purchases
    end

    def sellers_from_purchases(purchases)
      seller_counts = purchases.group(:seller_id).count
      sellers = User.where(id: seller_counts.keys).index_by(&:id)
      seller_counts.map do |seller_id, count|
        seller = sellers[seller_id]
        next if seller.nil?

        {
          id: seller.external_id,
          name: seller.name,
          purchases_count: count
        }
      end.compact
    end
end
