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
      params[:product_id] = @upsell.product.external_id unless params.key?(:product_id)
      params[:variant_id] = @upsell.variant&.external_id unless params.key?(:variant_id)
      params[:product_ids] = @upsell.selected_products.map(&:external_id) unless params.key?(:product_ids)

      unless params.key?(:upsell_variants)
        params[:upsell_variants] = @upsell.upsell_variants.alive.map do |upsell_variant|
          { selected_variant_id: upsell_variant.selected_variant.external_id, offered_variant_id: upsell_variant.offered_variant.external_id }
        end
      end

      unless params.key?(:offer_code)
        offer_code = @upsell.offer_code
        params[:offer_code] = offer_code.present? ? { amount_cents: offer_code.amount_cents, amount_percentage: offer_code.amount_percentage } : nil
      end
    end
end
