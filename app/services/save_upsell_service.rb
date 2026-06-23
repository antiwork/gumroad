# frozen_string_literal: true

class SaveUpsellService
  PERMITTED_PARAMS = [
    :name, :text, :description, :cross_sell, :product_id, :variant_id, :universal, :replace_selected_products, :paused,
    { offer_code: [:amount_cents, :amount_percentage], product_ids: [], upsell_variants: [:selected_variant_id, :offered_variant_id] }
  ].freeze

  def initialize(seller:, params:, upsell: nil)
    @seller = seller
    @params = params
    @existing_upsell = upsell
  end

  def perform
    @upsell = existing_upsell || seller.upsells.build

    assign_upsell_attributes

    if existing_upsell
      update_upsell_variants
      set_variant
    else
      set_variant
      create_upsell_variants
    end

    set_offer_code

    upsell
  end

  private
    attr_reader :seller, :params, :existing_upsell, :upsell

    def upsell_params
      @upsell_params ||= params.permit(*PERMITTED_PARAMS)
    end

    def assign_upsell_attributes
      upsell.assign_attributes(product: seller.products.find_by_external_id!(upsell_params[:product_id]), selected_products: seller.products.by_external_ids(upsell_params[:product_ids]), **upsell_params.except(:product_id, :variant_id, :product_ids, :offer_code, :upsell_variants))
    end

    def set_variant
      if upsell_params[:variant_id].present?
        upsell.variant = BaseVariant.find_by_external_id!(upsell_params[:variant_id])
      else
        upsell.variant = nil
      end
    end

    def set_offer_code
      if upsell_params[:offer_code].blank?
        upsell.offer_code&.mark_deleted!
        upsell.offer_code = nil
      else
        offer_code = upsell_params[:offer_code]
        offer_code[:amount_cents] ||= nil
        offer_code[:amount_percentage] ||= nil
        if upsell.offer_code.present?
          upsell.offer_code.assign_attributes(products: [upsell.product], **offer_code)
        else
          upsell.build_offer_code(user: seller, products: [upsell.product], **offer_code)
        end
      end
    end

    def create_upsell_variants
      if upsell_params[:upsell_variants].present?
        variants = upsell.product.variants_or_skus

        upsell_params[:upsell_variants].each do |upsell_variant|
          upsell.upsell_variants.build(selected_variant: variants.find_by_external_id(upsell_variant[:selected_variant_id]), offered_variant: variants.find_by_external_id(upsell_variant[:offered_variant_id]))
        end
      end
    end

    def update_upsell_variants
      variants = upsell.product.variants_or_skus
      new_upsell_variants = upsell_params[:upsell_variants] || []

      upsell.upsell_variants.alive.each do |upsell_variant|
        new_offered_variant = new_upsell_variants.find { |new_upsell_variant| new_upsell_variant[:selected_variant_id] == upsell_variant.selected_variant.external_id }
        if new_offered_variant.present?
          upsell_variant.offered_variant = variants.find_by_external_id!(new_offered_variant[:offered_variant_id])
        else
          upsell_variant.mark_deleted!
        end
      end

      new_upsell_variants.each do |new_upsell_variant|
        selected_variant = BaseVariant.find_by_external_id!(new_upsell_variant[:selected_variant_id])
        if upsell.upsell_variants.alive.find_by(selected_variant:).blank?
          upsell.upsell_variants.build(selected_variant:, offered_variant: BaseVariant.find_by_external_id!(new_upsell_variant[:offered_variant_id]))
        end
      end
    end
end
