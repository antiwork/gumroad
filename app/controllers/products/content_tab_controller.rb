# frozen_string_literal: true

class Products::ContentTabController < Products::BaseTabController
  def edit
    set_meta_tag(title: @product.name)
    render inertia: "Products/Edit/ContentTab", props: presenter.edit_props
  end

  def update
    handle_update do
      permitted = content_tab_params

      rich_content = permitted[:rich_content] || []
      rich_content_params = [*rich_content]
      permitted[:variants]&.each { rich_content_params.push(*_1[:rich_content]) }
      rich_content_params = rich_content_params.flat_map { _1[:description] = _1.dig(:description, :content) }

      SaveFilesService.perform(@product, permitted, rich_content_params)

      existing_rich_contents = @product.alive_rich_contents.to_a
      rich_contents_to_keep = []

      rich_content.each.with_index do |product_rich_content, index|
        rc = existing_rich_contents.find { |c| c.external_id == product_rich_content[:id] } ||
             @product.alive_rich_contents.build
        product_rich_content[:description] = SaveContentUpsellsService.new(
          seller: @product.user,
          content: product_rich_content[:description],
          old_content: rc.description || []
        ).from_rich_content
        rc.update!(
          title: product_rich_content[:title].presence,
          description: product_rich_content[:description].presence || [],
          position: index
        )
        rich_contents_to_keep << rc
      end

      (existing_rich_contents - rich_contents_to_keep).each(&:mark_deleted!)

      @product.assign_attributes(permitted.except(:rich_content, :variants, :files, :public_files))
      @product.save!
    end
  end

  private

    def content_tab_params
      params.require(:link).permit(
        :preview_url, :skus_enabled, :is_epublication,
        :has_same_rich_content_for_all_variants, :lock_version,
        files: {},
        public_files: {},
        rich_content: [:id, :title, description: {}],
        variants: [:id, rich_content: [:id, :title, description: {}]]
      )
    end
end
