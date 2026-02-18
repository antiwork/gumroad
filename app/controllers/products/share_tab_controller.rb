# frozen_string_literal: true

class Products::ShareTabController < Products::BaseTabController
  def edit
    set_meta_tag(title: @product.name)
    render inertia: "Products/Edit/ShareTab", props: presenter.edit_props
  end

  def update
    handle_update do
      permitted = share_tab_params
      @product.save_tags!(params[:link][:tags] || [])
      @product.show_in_sections!(params[:link][:section_ids] || [])
      @product.assign_attributes(permitted)
      update_custom_domain
      @product.save!
    end
  end

  private

    def share_tab_params
      params.require(:link).permit(
        :taxonomy_id, :display_product_reviews, :is_adult,
        :discover_fee_per_thousand, :lock_version
      )
    end

    def update_custom_domain
      custom_domain_value = params[:link][:custom_domain]
      return if custom_domain_value.nil?

      if custom_domain_value.present?
        custom_domain = @product.custom_domain || @product.build_custom_domain
        custom_domain.domain = custom_domain_value
        custom_domain.verify(allow_incrementing_failed_verification_attempts_count: false)
        custom_domain.save!
      elsif @product.custom_domain.present?
        @product.custom_domain.mark_deleted!
      end
    end
end
