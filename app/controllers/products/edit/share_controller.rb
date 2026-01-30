# frozen_string_literal: true

class Products::Edit::ShareController < Products::BaseController
  before_action :ensure_published

  def show
    props = presenter.edit_props

    render inertia: "Products/Edit/Share", props:
  end

  def update
    authorize @product

    ActiveRecord::Base.transaction do
      @product.assign_attributes(share_permitted_params.except(:tags, :section_ids))

      if share_permitted_params[:tags].present?
        @product.update_tags!(share_permitted_params[:tags])
      end

      if share_permitted_params[:section_ids].present?
        update_profile_sections(share_permitted_params[:section_ids])
      end

      @product.save!

      if params[:unpublish].present? && @product.published?
        @product.unpublish!
      end
    end

    if params[:unpublish].present?
      redirect_to product_edit_content_path(@product.unique_permalink), notice: "Unpublished!", status: :see_other
    else
      redirect_back fallback_location: product_edit_share_path(@product.unique_permalink), notice: "Changes saved!", status: :see_other
    end
  rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid => e
    error_message = @product.errors.full_messages.first || e.message
    redirect_to product_edit_share_path(@product.unique_permalink), alert: error_message
  end

  private
    def share_permitted_params
      params.permit(
        :taxonomy_id,
        :display_product_reviews,
        :is_adult,
        :discover_fee_per_thousand,
        section_ids: [],
        tags: []
      )
    end

    def update_profile_sections(section_ids)
      # Update which profile sections include this product
      @product.user.seller_profile_products_sections.each do |section|
        if section_ids.include?(section.external_id)
          section.add_product(@product.id) unless section.shown_products.include?(@product.id)
        else
          section.remove_product(@product.id) if section.shown_products.include?(@product.id)
        end
      end
    end

    def ensure_published
      return if @product.published?

      redirect_to product_edit_content_path(@product.unique_permalink),
                  alert: "Not yet! You've got to publish your awesome product before you can share it with your audience and the world."
    end
end
