# frozen_string_literal: true

class Api::V2::UpsellsController < Api::V2::BaseController
  before_action(only: [:index, :show]) { doorkeeper_authorize!(*Doorkeeper.configuration.public_api_read_scopes.concat([:view_public])) }
  before_action(only: [:create, :update, :destroy]) { doorkeeper_authorize! :edit_products }
  before_action :fetch_upsell, only: %i[show update destroy]

  def index
    success_with_object(:upsells, upsells_scope.includes(:product, :variant, :offer_code, :selected_products, upsell_variants: [:selected_variant, :offered_variant]))
  end

  def show
    success_with_upsell(@upsell)
  end

  def create
    @upsell = SaveUpsellService.new(seller: current_resource_owner, params:).perform
    if @upsell.save
      success_with_upsell(@upsell)
    else
      error_with_creating_object(:upsell, @upsell)
    end
  rescue ActiveRecord::RecordNotFound
    error_with_missing_reference
  end

  def update
    backfill_absent_associations
    SaveUpsellService.new(seller: current_resource_owner, params:, upsell: @upsell).perform
    if @upsell.save
      success_with_upsell(@upsell)
    else
      error_with_upsell(@upsell)
    end
  rescue ActiveRecord::RecordNotFound
    error_with_missing_reference
  end

  def destroy
    @upsell.offer_code&.mark_deleted
    @upsell.upsell_variants.each(&:mark_deleted)

    if @upsell.mark_deleted
      success_with_upsell
    else
      error_with_upsell(@upsell)
    end
  end

  private
    def upsells_scope
      current_resource_owner.upsells.alive.not_is_content_upsell
    end

    def fetch_upsell
      @upsell = upsells_scope.find_by_external_id(params[:id])
      error_with_upsell if @upsell.nil?
    end

    def success_with_upsell(upsell = nil)
      success_with_object(:upsell, upsell)
    end

    def error_with_upsell(upsell = nil)
      error_with_object(:upsell, upsell)
    end

    def error_with_missing_reference
      render_response(false, message: "The product, variant, or offer referenced by an external ID could not be found.")
    end

    def backfill_absent_associations
      product_changing = params[:product_id].present? && params[:product_id] != @upsell.product.external_id
      resulting_cross_sell = params.key?(:cross_sell) ? ActiveModel::Type::Boolean.new.cast(params[:cross_sell]) : @upsell.cross_sell

      params[:product_id] = @upsell.product.external_id unless params.key?(:product_id)

      # The offered version belongs to the offered product, so only preserve it for a
      # cross-sell whose product is unchanged; otherwise it no longer applies.
      unless params.key?(:variant_id)
        params[:variant_id] = resulting_cross_sell && !product_changing ? @upsell.variant&.external_id : nil
      end

      # Selected products are the cross-sell's audience and don't apply to a version upsell.
      unless params.key?(:product_ids)
        params[:product_ids] = resulting_cross_sell ? @upsell.selected_products.map(&:external_id) : []
      end

      # Version upgrades belong to the offered product and only apply to a version upsell.
      unless params.key?(:upsell_variants)
        params[:upsell_variants] = if resulting_cross_sell || product_changing
          []
        else
          @upsell.upsell_variants.alive.map do |upsell_variant|
            { selected_variant_id: upsell_variant.selected_variant.external_id, offered_variant_id: upsell_variant.offered_variant.external_id }
          end
        end
      end

      unless params.key?(:offer_code)
        offer_code = @upsell.offer_code
        params[:offer_code] = offer_code.present? ? { amount_cents: offer_code.amount_cents, amount_percentage: offer_code.amount_percentage } : nil
      end
    end
end
