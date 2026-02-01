# frozen_string_literal: true

class Products::ContentController < Products::BaseController
  def edit
    return redirect_to edit_bundle_content_path(@product.external_id) if @product.is_bundle?

    set_meta_tag(title: @product.name)

    render inertia: "Products/Content/Edit", props: presenter.edit_content_props
  end

  def update
    ActiveRecord::Base.transaction do
      # TODO: Update rich content for product and variants
      # Handle file uploads, content updates
      # Use SaveFilesService, SaveContentUpsellsService

      rich_content = content_permitted_params[:rich_content] || []
      rich_content_params = [*rich_content]
      content_permitted_params[:variants]&.each { rich_content_params.push(*_1[:rich_content]) }
      rich_content_params = rich_content_params.flat_map { _1[:description] = _1.dig(:description, :content) }

      rich_contents_to_keep = []
      SaveFilesService.perform(@product, content_permitted_params, rich_content_params)
      existing_rich_contents = @product.alive_rich_contents.to_a

      rich_content.each.with_index do |product_rich_content, index|
        rich_content_record = existing_rich_contents.find { |c| c.external_id === product_rich_content[:id] } || @product.alive_rich_contents.build
        product_rich_content[:description] = SaveContentUpsellsService.new(
          seller: @product.user,
          content: product_rich_content[:description],
          old_content: rich_content_record.description || []
        ).from_rich_content
        rich_content_record.update!(
          title: product_rich_content[:title].presence,
          description: product_rich_content[:description].presence || [],
          position: index
        )
        rich_contents_to_keep << rich_content_record
      end

      (existing_rich_contents - rich_contents_to_keep).each(&:mark_deleted!)

      update_variants_rich_content
      update_removed_file_attributes

      @product.is_licensed = @product.has_embedded_license_key?
      @product.is_multiseat_license = false unless @product.is_licensed
      @product.save!
      @product.generate_product_files_archives!
    end

    redirect_back fallback_location: edit_product_content_path(@product.external_id),
                  notice: "Changes saved!",
                  status: :see_other
  rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid => e
    error_message = @product.errors.full_messages.first || e.message
    redirect_to edit_product_content_path(@product.external_id), alert: error_message, inertia: inertia_errors(@product)
  end

  private
    def content_permitted_params
      params.permit(
        :has_same_rich_content_for_all_variants,
        rich_content: [:id, :title, description: {}],
        variants: [:id, rich_content: [:id, :title, description: {}]],
        files: [:id, :name, :external_id]
      )
    end

    def update_variants_rich_content
      return unless content_permitted_params[:variants].present?

      content_permitted_params[:variants].each do |variant_params|
        variant = @product.alive_variants.find_by(external_id: variant_params[:id])
        next unless variant

        rich_content = variant_params[:rich_content] || []
        existing_rich_contents = variant.alive_rich_contents.to_a
        rich_contents_to_keep = []

        rich_content.each.with_index do |variant_rich_content, index|
          rich_content_record = existing_rich_contents.find { |c| c.external_id === variant_rich_content[:id] } || variant.alive_rich_contents.build
          variant_rich_content[:description] = SaveContentUpsellsService.new(
            seller: @product.user,
            content: variant_rich_content[:description],
            old_content: rich_content_record.description || []
          ).from_rich_content
          rich_content_record.update!(
            title: variant_rich_content[:title].presence,
            description: variant_rich_content[:description].presence || [],
            position: index
          )
          rich_contents_to_keep << rich_content_record
        end

        (existing_rich_contents - rich_contents_to_keep).each(&:mark_deleted!)
      end
    end

    def update_removed_file_attributes
      return unless content_permitted_params[:files].present?

      file_ids = content_permitted_params[:files].map { _1[:id] }
      @product.files.where.not(id: file_ids).each do |file|
        FileAttribute.where(link_id: @product.id, customizable_file_id: file.id).delete_all
      end
    end
end
