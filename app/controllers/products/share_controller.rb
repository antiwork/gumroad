# frozen_string_literal: true

class Products::ShareController < Products::BaseController
  def edit
    return redirect_to edit_bundle_share_path(@product.external_id) if @product.is_bundle?

    set_meta_tag(title: @product.name)

    render inertia: "Products/Share/Edit", props: presenter.edit_share_props
  end

  def update
    ActiveRecord::Base.transaction do
      @product.save_tags!(share_permitted_params[:tags] || [])
      @product.show_in_sections!(share_permitted_params[:section_ids] || [])

      @product.assign_attributes(share_permitted_params.except(:tags, :section_ids, :custom_domain))

      update_custom_domain

      @product.save!
    end

    redirect_back fallback_location: edit_product_share_path(@product.external_id),
                  notice: "Changes saved!",
                  status: :see_other
  rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid => e
    error_message = @product.errors.full_messages.first || e.message
    redirect_to edit_product_share_path(@product.external_id), alert: error_message, inertia: inertia_errors(@product)
  end

  private
    def share_permitted_params
      params.permit(
        :taxonomy_id,
        :display_product_reviews,
        :is_adult,
        :custom_domain,
        tags: [],
        section_ids: []
      )
    end

    def update_custom_domain
      custom_domain = share_permitted_params[:custom_domain]
      return if custom_domain.nil?

      if custom_domain.blank?
        @product.custom_domain&.destroy
      elsif @product.custom_domain.present?
        @product.custom_domain.update!(domain: custom_domain)
      else
        @product.build_custom_domain(domain: custom_domain).save!
      end
    end
end
