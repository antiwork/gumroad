# frozen_string_literal: true

class Checkout::UpsellsController < Sellers::BaseController
  include Pagy::Backend

  PER_PAGE = 20

  def index
    authorize [:checkout, Upsell]

    @title = "Upsells"
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

    @upsell = current_seller.upsells.build

    assign_upsell_attributes

    set_variant

    create_upsell_variants

    set_offer_code

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

    assign_upsell_attributes

    update_upsell_variants

    set_variant

    set_offer_code

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
    def upsell_params
      params.permit(:name, :text, :description, :cross_sell, :product_id, :variant_id, :universal, :replace_selected_products, :paused, offer_code: [:amount_cents, :amount_percentage], product_ids: [], upsell_variants: [:selected_variant_id, :offered_variant_id])
    end

    def assign_upsell_attributes
      @upsell.assign_attributes(product: current_seller.products.find_by_external_id!(upsell_params[:product_id]), selected_products: current_seller.products.by_external_ids(upsell_params[:product_ids]), **upsell_params.except(:product_id, :variant_id, :product_ids, :offer_code, :upsell_variants))
    end

    def set_variant
      if params[:variant_id].present?
        @upsell.variant = BaseVariant.find_by_external_id!(upsell_params[:variant_id])
      else
        @upsell.variant = nil
      end
    end

    def set_offer_code
      if upsell_params[:offer_code].blank?
        @upsell.offer_code&.mark_deleted!
        @upsell.offer_code = nil
      else
        offer_code = upsell_params[:offer_code]
        offer_code[:amount_cents] ||= nil
        offer_code[:amount_percentage] ||= nil
        if @upsell.offer_code.present?
          @upsell.offer_code.assign_attributes(products: [@upsell.product], **offer_code)
        else
          @upsell.build_offer_code(user: current_seller, products: [@upsell.product], **offer_code)
        end
      end
    end

    def create_upsell_variants
      if upsell_params[:upsell_variants].present?
        variants = @upsell.product.variants_or_skus

        upsell_params[:upsell_variants].each do |upsell_variant|
          @upsell.upsell_variants.build(selected_variant: variants.find_by_external_id(upsell_variant[:selected_variant_id]), offered_variant: variants.find_by_external_id(upsell_variant[:offered_variant_id]))
        end
      end
    end

    def update_upsell_variants
      variants = @upsell.product.variants_or_skus
      new_upsell_variants = upsell_params[:upsell_variants] || []

      @upsell.upsell_variants.each do |upsell_variant|
        new_offered_variant = new_upsell_variants.find { |new_upsell_variant| new_upsell_variant[:selected_variant_id] == upsell_variant.selected_variant.external_id }
        if new_offered_variant.present?
          upsell_variant.offered_variant = variants.find_by_external_id!(new_offered_variant[:offered_variant_id])
        else
          upsell_variant.mark_deleted!
        end
      end

      new_upsell_variants.each do |new_upsell_variant|
        selected_variant = BaseVariant.find_by_external_id!(new_upsell_variant[:selected_variant_id])
        if @upsell.upsell_variants.find_by(selected_variant:).blank?
          @upsell.upsell_variants.build(selected_variant:, offered_variant: BaseVariant.find_by_external_id!(new_upsell_variant[:offered_variant_id]))
        end
      end
    end

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
