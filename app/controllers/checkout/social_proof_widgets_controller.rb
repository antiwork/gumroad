# frozen_string_literal: true

class Checkout::SocialProofWidgetsController < Sellers::BaseController
  include Pagy::Backend
  include CheckoutDashboardHelper

  PER_PAGE = 10

  def index
    authorize [:checkout, SocialProofWidget]

    @title = "Social Proof Widgets"
    pagination, widgets = fetch_widgets

    @presenter_data = {
      widgets: Checkout::SocialProofWidgetPresenter.listing_props_collection(widgets: widgets, current_user: current_seller),
      pagination: pagination,
      available_products: available_products_for_selection,
      image_type_options: Checkout::SocialProofWidgetPresenter.image_type_options,
      cta_type_options: Checkout::SocialProofWidgetPresenter.cta_type_options, 
      icon_options: Checkout::SocialProofWidgetPresenter.icon_options,
      pages: pages
    }
  end

  def paged
    authorize [:checkout, SocialProofWidget]

    pagination, widgets = fetch_widgets
    widget_props = Checkout::SocialProofWidgetPresenter.listing_props_collection(widgets: widgets, current_user: current_seller)

    render json: { widgets: widget_props, pagination: pagination }
  end

  def create
    authorize [:checkout, SocialProofWidget]

    widget = current_seller.social_proof_widgets.build(widget_params_without_products)
    widget.products = current_seller.links.alive.by_external_ids(widget_params[:product_ids]) if widget_params[:product_ids].present?

    attach_custom_image(widget) if widget_params[:custom_image_signed_blob_id].present?

    if widget.save
      presenter = Checkout::SocialProofWidgetPresenter.new(widget: widget, current_user: current_seller)
      render json: { success: true , widget: presenter.listing_props }
    else
      render json: { success: false, error_message: widget.errors.full_messages.first }
    end
  end

  def show
    widget = current_seller.social_proof_widgets.find_by_external_id!(params[:id])
    authorize [:checkout, widget]

    presenter = Checkout::SocialProofWidgetPresenter.new(widget: widget, current_user: current_seller)
    render json: presenter.edit_props
  end

  def update
    widget = current_seller.social_proof_widgets.find_by_external_id!(params[:id])
    authorize [:checkout, widget]

    widget.assign_attributes(widget_params_without_products)
    widget.products = current_seller.links.alive.by_external_ids(widget_params[:product_ids]) if widget_params[:product_ids].present?

    attach_custom_image(widget) if widget_params[:custom_image_signed_blob_id].present?

    if widget.save
      presenter = Checkout::SocialProofWidgetPresenter.new(widget: widget, current_user: current_seller)
      render json: { success: true, widget: presenter.listing_props }
    else
      render json: { success: false, error_message: widget.errors.full_messages.first }
    end
  end

  def destroy
    widget = current_seller.social_proof_widgets.find_by_external_id!(params[:id])
    authorize [:checkout, widget]

    if widget.mark_deleted!
      render json: { success: true }
    else
      render json: { success: false, error_message: widget.errors.full_messages.first }
    end
  end

  def duplicate
    original_widget = current_seller.social_proof_widgets.find_by_external_id!(params[:id])
    authorize [:checkout, original_widget]

    new_widget = current_seller.social_proof_widgets.build(
      name: "#{original_widget.name} (Copy)",
      universal: original_widget.universal,
      title: original_widget.title,
      description: original_widget.description,
      cta_text: original_widget.cta_text,
      cta_type: original_widget.cta_type,
      image_type: original_widget.image_type
    )

    new_widget.products = original_widget.products unless original_widget.universal?

    if original_widget.custom_image?
      new_widget.custom_image.attach(original_widget.custom_image.blob)
    end

    if new_widget.save
      presenter = Checkout::SocialProofWidgetPresenter.new(widget: new_widget, current_user: current_seller)
      render json: { success: true, widget: presenter.listing_props }
    else
      render json: { success: false, error_message: new_widget.errors.full_messages.first }
    end
  end

  private 

  def widget_params
    params.require(:social_proof_widget).permit(
      :name,
      :universal,
      :title,
      :description,
      :cta_text,
      :cta_type,
      :image_type,
      :status,
      :icon_color,
      :custom_image_signed_blob_id,
      product_ids: []
    )
  end

  def widget_params_without_products
    widget_params.except(:product_ids, :custom_image_signed_blob_id)
  end

  def attach_custom_image(widget)
    signed_blob_id = widget_params[:custom_image_signed_blob_id]
    return unless signed_blob_id.present?

    blob = ActiveStorage::Blob.find_signed(signed_blob_id)
    widget.custom_image.attach(blob)
  end

  def available_products_for_selection
    current_seller.links.alive.order(:name).map do |product|
      {
        id: product.external_id,
        name: product.name,
        thumbnail_url: product.thumbnail&.alive&.url
      }
    end
  end

  def fetch_widgets
    widgets = current_seller.social_proof_widgets
                            .alive
                            .includes(:products, custom_image_attachment: :blob)
                            .order(updated_at: :desc)

    widgets = widgets.where("name ILIKE ?", "%#{params[:query]}%") if params[:query].present?

    widgets_count = widgets.count
    total_pages = (widgets_count / PER_PAGE.to_f).ceil
    page_num = [params[:page].to_i, 1].max
    page_num = total_pages if page_num > total_pages && total_pages > 0

    pagination, widgets = pagy(widgets, page: page_num, limit: PER_PAGE)
    [PagyPresenter.new(pagination).props, widgets]
  end

end