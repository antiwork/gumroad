# frozen_string_literal: true

class Checkout::SocialProofWidgetsController < Sellers::BaseController
  include Pagy::Backend

  PER_PAGE = 20

  def index
    authorize [:checkout, SocialProofWidget]

    @title = "Social proof"
    pagination, social_proof_widgets = fetch_social_proof_widgets
    @social_proof_widget_props = Checkout::SocialProofWidgetsPresenter.new(pundit_user:, pagination:, social_proof_widgets:).social_proof_widgets_props
  end

  def paged
    authorize [:checkout, SocialProofWidget]

    pagination, social_proof_widgets = fetch_social_proof_widgets

    render json: { social_proof_widgets:, pagination: }
  end

  def create
    authorize [:checkout, SocialProofWidget]

    @social_proof_widget = current_seller.social_proof_widgets.build

    assign_social_proof_widget_attributes

    if @social_proof_widget.save
      pagination, social_proof_widgets = fetch_social_proof_widgets
      render json: { success: true, social_proof_widgets:, pagination: }
    else
      render json: { success: false, error: @social_proof_widget.errors.first.message }
    end
  end

  def update
    @social_proof_widget = current_seller.social_proof_widgets.find_by_external_id!(params[:id])
    authorize [:checkout, @social_proof_widget]

    assign_social_proof_widget_attributes

    if @social_proof_widget.save
      pagination, social_proof_widget = fetch_social_proof_widgets
      render json: { success: true, social_proof_widget:, pagination: }
    else
      render json: { success: false, error: @social_proof_widget.errors.first.message }
    end
  end

  def destroy
    social_proof_widget = current_seller.social_proof_widgets.find_by_external_id!(params[:id])
    authorize [:checkout, SocialProofWidget]

    if social_proof_widget.mark_deleted
      pagination, social_proof_widget = fetch_social_proof_widgets
      render json: { success: true, social_proof_widget:, pagination: }
    else
      render json: { success: false, error: social_proof_widget.errors.first.message }
    end
  end


  private
    def social_proof_widget_params
      params.permit(:name, :text, :description, :cross_sell, :product_id, :variant_id, :universal, :replace_selected_products, offer_code: [:amount_cents, :amount_percentage], product_ids: [], upsell_variants: [:selected_variant_id, :offered_variant_id])
    end

    def assign_social_proof_widget_attributes
      @social_proof_widget.assign_attributes(product: current_seller.products.find_by_external_id!(social_proof_widget_params[:product_id]), selected_products: current_seller.products.by_external_ids(social_proof_widget_params[:product_ids]), **social_proof_widget_params.except(:product_id, :variant_id, :product_ids, :offer_code, :upsell_variants))
    end

    def paged_params
      params.permit(:page, sort: [:key, :direction])
    end

    def fetch_social_proof_widgets
      social_proof_widgets = current_seller.social_proof_widgets
                      .alive
                      .sorted_by(**paged_params[:sort].to_h.symbolize_keys)
                      .order(updated_at: :desc)
      social_proof_widgets = social_proof_widgets.where("name LIKE :query", query: "%#{params[:query]}%") if params[:query].present?

      pagination, social_proof_widgets = pagy(social_proof_widgets, page: [paged_params[:page].to_i, 1].max, limit: PER_PAGE)

      [PagyPresenter.new(pagination).props, social_proof_widgets]
    end
end
