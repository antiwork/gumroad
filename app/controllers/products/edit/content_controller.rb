# frozen_string_literal: true

class Products::Edit::ContentController < Products::BaseController
  def show
    props = presenter.edit_props

    render inertia: "Products/Edit/Content", props:
  end

  def update
    authorize @product

    should_publish = params[:publish].present? && !@product.published?
    should_unpublish = params[:unpublish].present? && @product.published?

    ActiveRecord::Base.transaction do
      @product.assign_attributes(content_permitted_params.except(:rich_content, :variants))

      if content_permitted_params[:rich_content].present?
        @product.update_rich_content!(content_permitted_params[:rich_content])
      end

      if content_permitted_params[:variants].present?
        update_variants_content(content_permitted_params[:variants])
      end

      @product.save!

      @product.publish! if should_publish
      @product.unpublish! if should_unpublish
    end

    if should_publish
      redirect_to product_edit_share_path(@product.unique_permalink), notice: "Published!", status: :see_other
    elsif should_unpublish
      redirect_back fallback_location: product_edit_content_path(@product.unique_permalink), notice: "Unpublished!", status: :see_other
    elsif params[:redirect_to].present?
      redirect_to params[:redirect_to], notice: "Changes saved!", status: :see_other
    else
      redirect_back fallback_location: product_edit_content_path(@product.unique_permalink), notice: "Changes saved!", status: :see_other
    end
  rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid => e
    error_message = @product.errors.full_messages.first || e.message
    redirect_to product_edit_content_path(@product.unique_permalink), alert: error_message
  end

  private
    def content_permitted_params
      params.permit(
        :has_same_rich_content_for_all_variants,
        rich_content: {},
        variants: [:id, rich_content: {}]
      )
    end

    def update_variants_content(variants_params)
      variants_params.each do |variant_params|
        variant = @product.alive_variants.find_by(external_id: variant_params[:id])
        next unless variant && variant_params[:rich_content].present?

        variant.update_rich_content!(variant_params[:rich_content])
      end
    end
end
