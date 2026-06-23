# frozen_string_literal: true

class Checkout::UpsellsController < Sellers::BaseController
  include Pagy::Backend

  PER_PAGE = 20

  layout "inertia", only: [:index]

  def index
    authorize [:checkout, Upsell]

    set_meta_tag(title: "Upsells")
    pagination, upsells = fetch_upsells
    upsells_props = Checkout::UpsellsPresenter.new(pundit_user:, pagination:, upsells:).upsells_props

    render inertia: "Checkout/Upsells/Index",
           props: upsells_props
  end

  def paged
    authorize [:checkout, Upsell]

    pagination, upsells = fetch_upsells

    render json: { upsells:, pagination: }
  end

  def cart_item
    authorize [:checkout, Upsell]

    product = current_seller.products.find_by_external_id!(params[:product_id])

    checkout_presenter = CheckoutPresenter.new(logged_in_user: nil, ip: nil)
    render json: checkout_presenter.checkout_product(
      product,
      product.cart_item({
                          option: product.is_tiered_membership ? product.alive_variants.first.external_id : nil
                        }),
      {}
    )
  end

  def create
    authorize [:checkout, Upsell]

    @upsell = SaveUpsellService.new(seller: current_seller, params:).perform

    if @upsell.save
      pagination, upsells = fetch_upsells
      render json: { success: true, upsells:, pagination: }
    else
      render json: { success: false, error: @upsell.errors.first.message }
    end
  end

  def update
    @upsell = current_seller.upsells.includes(:product, :offer_code, upsell_variants: [:selected_variant]).find_by_external_id!(params[:id])
    authorize [:checkout, @upsell]

    SaveUpsellService.new(seller: current_seller, params:, upsell: @upsell).perform

    if @upsell.save
      pagination, upsells = fetch_upsells
      render json: { success: true, upsells:, pagination: }
    else
      render json: { success: false, error: @upsell.errors.first.message }
    end
  end

  def destroy
    upsell = current_seller.upsells.includes(:offer_code, :upsell_variants).find_by_external_id!(params[:id])
    authorize [:checkout, upsell]

    upsell.offer_code&.mark_deleted
    upsell.upsell_variants.each(&:mark_deleted)

    if upsell.mark_deleted
      pagination, upsells = fetch_upsells
      render json: { success: true, upsells:, pagination: }
    else
      render json: { success: false, error: upsell.errors.first.message }
    end
  end

  def statistics
    upsell = current_seller.upsells.alive.find_by_external_id!(params[:id])
    authorize [:checkout, upsell]

    statistics = upsell.purchases_that_count_towards_volume
      .group(:selected_product_id, :upsell_variant_id)
      .select(:selected_product_id, :upsell_variant_id, "SUM(quantity) as total_quantity", "SUM(price_cents) as total_price_cents")

    selected_products = {}
    upsell_variants = {}
    total = 0
    revenue_cents = 0

    statistics.each do |record|
      product_id = ObfuscateIds.encrypt(record.selected_product_id)
      selected_products[product_id] = (selected_products[product_id] || 0) + record.total_quantity
      upsell_variants[ObfuscateIds.encrypt(record.upsell_variant_id)] = record.total_quantity if record.upsell_variant_id.present?
      total += record.total_quantity
      revenue_cents += record.total_price_cents
    end

    render json: {
      uses: {
        total:,
        selected_products:,
        upsell_variants:,
      },
      revenue_cents:,
    }
  end

  private
    def paged_params
      params.permit(:page, sort: [:key, :direction])
    end

    def fetch_upsells
      upsells = current_seller.upsells
                      .alive
                      .not_is_content_upsell
                      .sorted_by(**paged_params[:sort].to_h.symbolize_keys)
                      .order(updated_at: :desc)
      upsells = upsells.where("name LIKE :query", query: "%#{params[:query]}%") if params[:query].present?

      pagination, upsells = pagy(upsells, page: [paged_params[:page].to_i, 1].max, limit: PER_PAGE)

      [PagyPresenter.new(pagination).props, upsells]
    end
end
