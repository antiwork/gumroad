# frozen_string_literal: true

class Products::Edit::BaseController < ApplicationController
  include ProductsHelper, SearchProducts, PreorderHelper, ActionView::Helpers::TextHelper,
          ActionView::Helpers::AssetUrlHelper, CustomDomainConfig, AffiliateCookie,
          CreateDiscoverSearch, DiscoverCuratedProducts, FetchProductByUniquePermalink

  include PageMeta::Favicon, PageMeta::Product

  before_action :authenticate_user!
  after_action :verify_authorized

  before_action :fetch_product_by_unique_permalink
  before_action :authorize_product

  layout "inertia", only: [:show]

  private
    def authorize_product
      authorize @product
    end

  protected
    def product_permitted_params
      @_product_permitted_params ||= params.permit(policy(@product).product_permitted_attributes)
    end

    def set_product_title
      set_meta_tag(title: @product.name)
    end

    # Helper methods shared across all edit controllers
    def update_removed_file_attributes
      current = @product.file_info_for_product_page.keys.map(&:to_s)
      updated = (product_permitted_params[:file_attributes] || []).map { _1[:name] }
      @product.add_removed_file_info_attributes(current - updated)
    end

    def update_variants
      variant_category = @product.variant_categories_alive.first
      variants = product_permitted_params[:variants] || []
      if variants.any? || @product.is_tiered_membership?
        variant_category_params = variant_category.present? ?
          {
            id: variant_category.external_id,
            name: variant_category.title,
          } :
          { name: @product.is_tiered_membership? ? "Tier" : "Version" }
        Product::VariantsUpdaterService.new(
          product: @product,
          variants_params: [
            {
              **variant_category_params,
              options: variants,
            }
          ],
        ).perform
      elsif variant_category.present?
        Product::VariantsUpdaterService.new(
          product: @product,
          variants_params: [
            {
              id: variant_category.external_id,
              options: nil,
            }
          ]).perform
      end
    end

    def update_custom_domain
      if product_permitted_params[:custom_domain].present?
        custom_domain = @product.custom_domain || @product.build_custom_domain
        custom_domain.domain = product_permitted_params[:custom_domain]
        custom_domain.verify(allow_incrementing_failed_verification_attempts_count: false)
        custom_domain.save!
      elsif product_permitted_params[:custom_domain] == "" && @product.custom_domain.present?
        @product.custom_domain.mark_deleted!
      end
    end

    def update_availabilities
      return unless @product.native_type == Link::NATIVE_TYPE_CALL

      existing_availabilities = @product.call_availabilities
      availabilities_to_keep = []
      (product_permitted_params[:availabilities] || []).each do |availability_params|
        availability = existing_availabilities.find { _1.id == availability_params[:id] } || @product.call_availabilities.build
        availability.update!(availability_params.except(:id))
        availabilities_to_keep << availability
      end
      (existing_availabilities - availabilities_to_keep).each(&:destroy!)
    end

    def update_call_limitation_info
      return unless @product.native_type == Link::NATIVE_TYPE_CALL

      @product.call_limitation_info.update!(product_permitted_params[:call_limitation_info])
    end

    def update_installment_plan
      return unless @product.eligible_for_installment_plans?

      if @product.installment_plan && product_permitted_params[:installment_plan].present?
        @product.installment_plan.assign_attributes(product_permitted_params[:installment_plan])
        return unless @product.installment_plan.changed?
      end

      @product.installment_plan&.destroy_if_no_payment_options!
      @product.reset_installment_plan

      if product_permitted_params[:installment_plan].present?
        @product.create_installment_plan!(product_permitted_params[:installment_plan])
      end
    end

    def update_default_offer_code
      default_offer_code_id = product_permitted_params[:default_offer_code_id]

      return @product.default_offer_code = nil if default_offer_code_id.blank?

      offer_code = @product.user.offer_codes.alive.find_by_external_id!(default_offer_code_id)

      raise Link::LinkInvalid, "Offer code cannot be expired" if offer_code.inactive?
      raise Link::LinkInvalid, "Offer code must be associated with this product or be universal" unless valid_for_product?(offer_code)

      @product.default_offer_code = offer_code
    rescue ActiveRecord::RecordNotFound
      raise Link::LinkInvalid, "Invalid offer code"
    end

    def toggle_community_chat!(enabled)
      return unless Feature.active?(:communities, current_seller)
      return if [Link::NATIVE_TYPE_COFFEE, Link::NATIVE_TYPE_BUNDLE].include?(@product.native_type)

      @product.toggle_community_chat!(enabled)
    end

  private
    def valid_for_product?(offer_code)
      offer_code.universal? || @product.offer_codes.where(id: offer_code.id).exists?
    end
end
