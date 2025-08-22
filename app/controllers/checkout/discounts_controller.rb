# frozen_string_literal: true

class Checkout::DiscountsController < Sellers::BaseController
  include Pagy::Backend

  PER_PAGE = 10

  before_action :clean_params, only: [:create, :update]

  def index
    authorize [:checkout, OfferCode]

    respond_to do |format|
      format.html do
        @title = "Discounts"
        pagination, offer_codes = fetch_offer_codes
        @presenter = Checkout::DiscountsPresenter.new(pundit_user:, offer_codes:, pagination:)
      end
      format.csv do
        csv_data = generate_csv_with_filters
        send_data csv_data, filename: "discounts-#{Date.current}.csv", type: 'text/csv'
      end
    end
  end

  def paged
    authorize [:checkout, OfferCode]

    pagination, offer_codes = fetch_offer_codes
    @presenter = Checkout::DiscountsPresenter.new(pundit_user:)

    render json: { offer_codes: offer_codes.map { @presenter.offer_code_props(_1) }, pagination: }
  end

  def statistics
    offer_code = OfferCode.find_by_external_id!(params[:id])
    authorize [:checkout, offer_code]

    purchases = offer_code.purchases.counts_towards_offer_code_uses
    statistics = purchases.group(:link_id).pluck(:link_id, "SUM(quantity)", "SUM(price_cents)")

    products = {}
    total = 0
    revenue_cents = 0

    statistics.each do |(link_id, total_quantity, total_price_cents)|
      products[ObfuscateIds.encrypt(link_id)] = total_quantity
      total += total_quantity
      revenue_cents += total_price_cents
    end

    render json: { uses: { total:, products: }, revenue_cents: }
  end

  def create
    authorize [:checkout, OfferCode]

    parse_date_times
    params = offer_code_params.except(:selected_product_ids)

    # Convert external collection ID to internal ID
    if params[:discount_collection_id].present?
      collection = DiscountCollection.find_by_external_id(params[:discount_collection_id])
      params[:discount_collection_id] = collection&.id
    end

    offer_code = current_seller.offer_codes.build(products: current_seller.products.by_external_ids(offer_code_params[:selected_product_ids]), **params)

    if offer_code.save
      pagination, offer_codes = fetch_offer_codes
      presenter = Checkout::DiscountsPresenter.new(pundit_user:)
      render json: { success: true, offer_codes: offer_codes.map { presenter.offer_code_props(_1) }, pagination: }
    else
      render json: { success: false, error_message: offer_code.errors.full_messages.first }
    end
  end

  def update
    offer_code = OfferCode.find_by_external_id!(params[:id])
    authorize [:checkout, offer_code]

    parse_date_times
    params = offer_code_params.except(:selected_product_ids, :code)

    # Convert external collection ID to internal ID
    if params[:discount_collection_id].present?
      collection = DiscountCollection.find_by_external_id(params[:discount_collection_id])
      params[:discount_collection_id] = collection&.id
    end

    if offer_code.update(**params, products: current_seller.products.by_external_ids(offer_code_params[:selected_product_ids]))
      pagination, offer_codes = fetch_offer_codes
      presenter = Checkout::DiscountsPresenter.new(pundit_user:)
      render json: { success: true, offer_codes: offer_codes.map { presenter.offer_code_props(_1) }, pagination: }
    else
      render json: { success: false, error_message: offer_code.errors.full_messages.first }
    end
  end

  def destroy
    offer_code = OfferCode.find_by_external_id!(params[:id])
    authorize [:checkout, offer_code]

    if offer_code.mark_deleted(validate: false)
      render json: { success: true }
    else
      render json: { success: false, error_message: offer_code.errors.full_messages.first }
    end
  end

  private
    def offer_code_params
      params.permit(:name, :code, :universal, :max_purchase_count, :amount_cents, :amount_percentage, :currency_type, :valid_at, :expires_at, :minimum_quantity, :duration_in_billing_cycles, :minimum_amount_cents, :discount_collection_id, selected_product_ids: [])
    end

    def paged_params
      params.permit(:page, :query, :collection_filter, :collection_id, :format, sort: [:key, :direction])
    end

    def clean_params
      params[:currency_type] = nil if params[:currency_type].blank?
      if offer_code_params[:amount_percentage].present?
        params[:amount_cents] = nil
        params[:currency_type] = nil
      else
        params[:amount_percentage] = nil
      end
    end

    def parse_date_times
      offer_code_params[:valid_at] = Date.parse(offer_code_params[:valid_at]) if offer_code_params[:valid_at].present?
      offer_code_params[:expires_at] = Date.parse(offer_code_params[:expires_at]) if offer_code_params[:expires_at].present?
    end

    def fetch_offer_codes
      # Map user-facing query params to internal params
      params[:sort] = { key: params[:column], direction: params[:sort] } if params[:column].present? && params[:sort].present?

      offer_codes = current_seller.offer_codes
                      .alive
                      .where.not(code: nil)
                      .includes(:discount_collection)
                      .preload(:products)
                      .sorted_by(**paged_params[:sort].to_h.symbolize_keys).order(updated_at: :desc)
      offer_codes = offer_codes.where("name LIKE :query OR code LIKE :query", query: "%#{paged_params[:query]}%") if paged_params[:query].present?

      # Filter by collection - default to hiding collection discounts if no filter specified
      if paged_params[:collection_filter].present?
        case paged_params[:collection_filter]
        when 'in_collections'
          offer_codes = offer_codes.where.not(discount_collection_id: nil)
        when 'not_in_collections'
          offer_codes = offer_codes.where(discount_collection_id: nil)
        when 'specific_collection'
          if paged_params[:collection_id].present?
            collection = DiscountCollection.find_by_external_id(paged_params[:collection_id])
            if collection
              offer_codes = offer_codes.where(discount_collection_id: collection.id)
            else
              # If collection not found, show no results
              offer_codes = offer_codes.where(id: nil)
            end
          end
        when 'all'
          # Show all discounts (no filtering)
        end
      else
        # Default behavior: hide collection discounts
        offer_codes = offer_codes.where(discount_collection_id: nil)
      end

      offer_codes_count = offer_codes.count.is_a?(Hash) ? offer_codes.count.length : offer_codes.count

      # Map invalid page numbers to the closest valid page number
      total_pages = (offer_codes_count / PER_PAGE.to_f).ceil
      page_num = paged_params[:page].to_i
      if page_num <= 0
        page_num = 1
      elsif page_num > total_pages && total_pages != 0
        page_num = total_pages
      end

      pagination, offer_codes = pagy(offer_codes, page: page_num, limit: PER_PAGE)

      [PagyPresenter.new(pagination).props, offer_codes]
    end

    def generate_csv_with_filters
      require 'csv'

      # Apply the same filters as fetch_offer_codes but without pagination
      offer_codes = current_seller.offer_codes
                      .alive
                      .where.not(code: nil)
                      .includes(:discount_collection, :products)
                      .sorted_by(**paged_params[:sort].to_h.symbolize_keys).order(updated_at: :desc)

      offer_codes = offer_codes.where("name LIKE :query OR code LIKE :query", query: "%#{paged_params[:query]}%") if paged_params[:query].present?

      # Filter by collection - default to hiding collection discounts if no filter specified
      if paged_params[:collection_filter].present?
        case paged_params[:collection_filter]
        when 'in_collections'
          offer_codes = offer_codes.where.not(discount_collection_id: nil)
        when 'not_in_collections'
          offer_codes = offer_codes.where(discount_collection_id: nil)
        when 'specific_collection'
          if paged_params[:collection_id].present?
            collection = DiscountCollection.find_by_external_id(paged_params[:collection_id])
            if collection
              offer_codes = offer_codes.where(discount_collection_id: collection.id)
            else
              # If collection not found, show no results
              offer_codes = offer_codes.where(id: nil)
            end
          end
        when 'all'
          # Show all discounts (no filtering)
        end
      else
        # Default behavior: hide collection discounts
        offer_codes = offer_codes.where(discount_collection_id: nil)
      end

      CSV.generate(headers: true) do |csv|
        csv << [
          'Code',
          'Name',
          'Discount Type',
          'Discount Value',
          'Products',
          'Max Uses',
          'Valid From',
          'Expires At',
          'Collection',
          'Created At'
        ]

        offer_codes.each do |offer_code|
          csv << [
            offer_code.code,
            offer_code.name,
            offer_code.amount_cents.present? ? 'cents' : 'percent',
            offer_code.amount_cents || offer_code.amount_percentage,
            offer_code.universal ? 'All Products' : offer_code.products.map(&:name).join(', '),
            offer_code.max_purchase_count,
            offer_code.valid_at&.strftime('%Y-%m-%d'),
            offer_code.expires_at&.strftime('%Y-%m-%d'),
            offer_code.discount_collection&.name,
            offer_code.created_at.strftime('%Y-%m-%d %H:%M:%S')
          ]
        end
      end
    end

    def generate_csv(offer_codes)
      require 'csv'

      CSV.generate(headers: true) do |csv|
        csv << [
          'Code',
          'Name',
          'Discount Type',
          'Discount Value',
          'Products',
          'Max Uses',
          'Valid From',
          'Expires At',
          'Collection',
          'Created At'
        ]

        offer_codes.each do |offer_code|
          csv << [
            offer_code.code,
            offer_code.name,
            offer_code.amount_cents.present? ? 'cents' : 'percent',
            offer_code.amount_cents || offer_code.amount_percentage,
            offer_code.universal ? 'All Products' : offer_code.products.map(&:name).join(', '),
            offer_code.max_purchase_count,
            offer_code.valid_at&.strftime('%Y-%m-%d'),
            offer_code.expires_at&.strftime('%Y-%m-%d'),
            offer_code.discount_collection&.name,
            offer_code.created_at.strftime('%Y-%m-%d %H:%M:%S')
          ]
        end
      end
    end
end
