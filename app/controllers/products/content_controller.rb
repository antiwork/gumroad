# frozen_string_literal: true

class Products::ContentController < Products::BaseController
  def edit
    render inertia: "Products/Content/Edit", props: Products::Edit::ContentTabPresenter.new(product: @product, pundit_user:).props
  end

  def update
    authorize @product

    should_publish = params[:publish].present? && !@product.published?
    should_unpublish = params[:unpublish].present? && @product.published?

    if should_unpublish
      @product.unpublish!
      check_offer_codes_validity
      return redirect_back fallback_location: edit_product_content_path(@product.unique_permalink), notice: "Unpublished!", status: :see_other
    end

    # Publish-only request (e.g. after "Save" then "Publish and continue" from frontend)
    if should_publish && params[:product].blank?
      @product.publish!
      check_offer_codes_validity
      return redirect_to edit_product_share_path(@product.unique_permalink), notice: "Published!", status: :see_other
    end

    ActiveRecord::Base.transaction do
      update_content_attributes
      @product.publish! if should_publish
    end

    check_offer_codes_validity

    if should_publish
      redirect_to edit_product_share_path(@product.unique_permalink), notice: "Published!", status: :see_other
    elsif params[:redirect_to].present?
      redirect_to params[:redirect_to], notice: "Changes saved!", status: :see_other
    else
      redirect_back fallback_location: edit_product_content_path(@product.unique_permalink), notice: "Changes saved!", status: :see_other
    end
  rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid => e
    error_message = @product.errors.full_messages.first || e.message
    redirect_to edit_product_content_path(@product.unique_permalink), alert: error_message, status: :see_other
  end

  private
    def update_content_attributes
      @product.assign_attributes(product_permitted_params.except(:files, :variants, :custom_domain, :rich_content))
      SaveFilesService.perform(@product, product_permitted_params, rich_content_params)
      update_rich_content
      @product.save!
      @product.generate_product_files_archives!
    end

    def update_rich_content
      rich_content = product_permitted_params[:rich_content] || []
      existing_rich_contents = @product.alive_rich_contents.to_a
      rich_contents_to_keep = []

      rich_content.each.with_index do |product_rich_content, index|
        rc = existing_rich_contents.find { |c| c.external_id === product_rich_content[:id] } || @product.alive_rich_contents.build
        description = product_rich_content[:description].to_h[:content]
        product_rich_content[:description] = SaveContentUpsellsService.new(
          seller: @product.user,
          content: description,
          old_content: rc.description || []
        ).from_rich_content
        rc.update!(title: product_rich_content[:title].presence, description: product_rich_content[:description].presence || [], position: index)
        rich_contents_to_keep << rc
      end

      (existing_rich_contents - rich_contents_to_keep).each(&:mark_deleted!)
    end

    def rich_content_params
      rich_content = product_permitted_params[:rich_content] || []
      list = [*rich_content]
      product_permitted_params[:variants]&.each { list.push(*_1[:rich_content]) }
      list.map { _1.dig(:description, :content) }
    end

    def product_permitted_params
      params.require(:product).permit(policy(@product).content_tab_permitted_attributes)
    end
end
