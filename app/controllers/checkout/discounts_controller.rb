# frozen_string_literal: true

class Checkout::DiscountsController < Sellers::BaseController
  include Pagy::Backend

  PER_PAGE = 10

  before_action :clean_params, only: [:create, :update]

  layout "inertia", only: [:index]

  def index
    authorize [:checkout, OfferCode]

    @title = "Discounts"
    pagination, offer_codes = fetch_offer_codes
    presenter = Checkout::DiscountsPresenter.new(pundit_user:, offer_codes:, pagination:)

    render inertia: "Checkout/Discounts/Index",
           props: presenter.discounts_props
  end

  def paged
    authorize [:checkout, OfferCode]

    pagination, offer_codes = fetch_offer_codes
    presenter = Checkout::DiscountsPresenter.new(pundit_user:)

    render json: { offer_codes: offer_codes.map { presenter.offer_code_props(_1) }, pagination: }
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
    offer_code = current_seller.offer_codes.build(products: current_seller.products.by_external_ids(offer_code_params[:selected_product_ids]), **offer_code_params.except(:selected_product_ids))

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
    if offer_code.update(**offer_code_params.except(:selected_product_ids, :code), products: current_seller.products.by_external_ids(offer_code_params[:selected_product_ids]))
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
      params.permit(:name, :code, :universal, :max_purchase_count, :amount_cents, :amount_percentage, :currency_type, :valid_at, :expires_at, :minimum_quantity, :duration_in_billing_cycles, :minimum_amount_cents, selected_product_ids: [])
    end

    def paged_params
      params.permit(:page, sort: [:key, :direction])
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
      offer_code_params[:valid_at] = Time.zone.parse(offer_code_params[:valid_at]) if offer_code_params[:valid_at].present?
      offer_code_params[:expires_at] = Time.zone.parse(offer_code_params[:expires_at]) if offer_code_params[:expires_at].present?
    end

    def fetch_offer_codes
      # Map user-facing query params to internal params
      params[:sort] = { key: params[:column], direction: params[:sort] } if params[:column].present? && params[:sort].present?

      offer_codes = current_seller.offer_codes
                      .alive
                      .where.not(code: nil)
                      .includes(:products)
                      .sorted_by(**paged_params[:sort].to_h.symbolize_keys).order(updated_at: :desc)
      offer_codes = offer_codes.where("name LIKE :query OR code LIKE :query", query: "%#{params[:query]}%") if params[:query].present?
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
end
