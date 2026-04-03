# frozen_string_literal: true

class Api::V2::LinksController < Api::V2::BaseController
  before_action(only: [:show, :index]) { doorkeeper_authorize!(*Doorkeeper.configuration.public_scopes.concat([:view_public])) }
  before_action(only: [:create, :update, :disable, :enable, :destroy]) { doorkeeper_authorize! :edit_products }
  before_action :check_types_of_file_objects, only: [:update, :create]
  before_action :set_link_id_to_id, only: [:show, :update, :disable, :enable, :destroy]
  before_action :fetch_product, only: [:show, :update, :disable, :enable, :destroy]

  def index
    products = current_resource_owner.products.visible.includes(
      :preorder_link, :tags, :taxonomy,
      variant_categories_alive: [:alive_variants],
    ).order(created_at: :desc)

    as_json_options = {
      api_scopes: doorkeeper_token.scopes,
      preloaded_ppp_factors: PurchasingPowerParityService.new.get_all_countries_factors(current_resource_owner)
    }

    products_as_json = products.as_json(as_json_options)

    render json: { success: true, products: products_as_json }
  end

  def create
    e404
  end

  def show
    success_with_product(@product)
  end

  def update
    if @product.is_tiered_membership && params.key?(:price)
      return render_response(false, message: "Price cannot be updated for tiered membership products. Use the variant endpoints to manage tier pricing.")
    end

    @normalized_files = normalize_params_recursively(params[:files]) if params.key?(:files)
    @normalized_rich_content = normalize_params_recursively(params[:rich_content]) if params.key?(:rich_content)

    begin
      ActiveRecord::Base.transaction do
        attrs = {}
        attrs[:name] = params[:name] if params.key?(:name)
        attrs[:custom_permalink] = params[:custom_permalink] if params.key?(:custom_permalink)
        attrs[:price_cents] = params[:price] if params.key?(:price)
        attrs[:price_currency_type] = params[:price_currency_type] if params.key?(:price_currency_type)
        attrs[:customizable_price] = params[:customizable_price] if params.key?(:customizable_price)
        attrs[:suggested_price_cents] = params[:suggested_price_cents] if params.key?(:suggested_price_cents)
        attrs[:max_purchase_count] = params[:max_purchase_count] if params.key?(:max_purchase_count)
        attrs[:quantity_enabled] = params[:quantity_enabled] if params.key?(:quantity_enabled)
        attrs[:is_adult] = params[:is_adult] if params.key?(:is_adult)
        attrs[:display_product_reviews] = params[:display_product_reviews] if params.key?(:display_product_reviews)
        attrs[:should_show_sales_count] = params[:should_show_sales_count] if params.key?(:should_show_sales_count)
        attrs[:taxonomy_id] = params[:taxonomy_id] if params.key?(:taxonomy_id)
        attrs[:custom_receipt] = params[:custom_receipt] if params.key?(:custom_receipt)

        @rich_content_flag_was = @product.has_same_rich_content_for_all_variants?

        if params.key?(:has_same_rich_content_for_all_variants)
          attrs[:has_same_rich_content_for_all_variants] = ActiveModel::Type::Boolean.new.cast(params[:has_same_rich_content_for_all_variants])
        end

        @product.assign_attributes(attrs)

        if params.key?(:description)
          @product.description = SaveContentUpsellsService.new(seller: @product.user, content: params[:description], old_content: @product.description_was).from_html
        end

        if params.key?(:custom_summary)
          @product.json_data["custom_summary"] = params[:custom_summary]
        end

        flag_changed = @product.has_same_rich_content_for_all_variants? != @rich_content_flag_was

        unless @normalized_files.nil?
          validate_file_embed_conflicts!(skip_variant_embeds: flag_changed && @product.has_same_rich_content_for_all_variants? && !@normalized_rich_content.nil?)

          rich_content_params = build_rich_content_params
          SaveFilesService.perform(@product, { files: @normalized_files }, rich_content_params)
        end

        @product.save!

        @product.save_tags!(params[:tags]) if params.key?(:tags)

        if params.key?(:cover_ids)
          cover_ids = normalize_params_recursively(params[:cover_ids])
          @product.reorder_previews(cover_ids.map.with_index.to_h)
        end

        if !@normalized_rich_content.nil? && !@product.has_same_rich_content_for_all_variants? && @product.alive_variants.exists?
          raise Link::LinkInvalid, "Cannot update product-level rich content while in per-variant mode. Set has_same_rich_content_for_all_variants to true first, or use the variant endpoint to update per-variant content."
        end

        if flag_changed
          if @normalized_rich_content.nil?
            migrate_rich_content_for_flag_change!
          else
            clear_inactive_rich_content_side!
            strip_upsell_ids_from_normalized_rich_content!
          end
        end

        rich_content_or_flag_changed = !@normalized_rich_content.nil? || flag_changed

        unless @normalized_rich_content.nil?
          save_rich_content!
        end

        if rich_content_or_flag_changed
          Product::SavePostPurchaseCustomFieldsService.new(@product).perform
          @product.is_licensed = @product.has_embedded_license_key?
          @product.is_multiseat_license = false if !@product.is_licensed
          @product.save!
        end

        @product.generate_product_files_archives! if !@normalized_files.nil? || rich_content_or_flag_changed
      end
    rescue Link::LinkInvalid => e
      return if performed?
      return render_response(false, message: e.message)
    rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid => e
      return if performed?
      object = e.respond_to?(:record) ? e.record : nil
      if object == @product || object.nil?
        return error_with_product(@product)
      else
        return render_response(false, message: object.errors.full_messages.to_sentence)
      end
    end

    offer_code_warning = check_offer_code_validity
    if offer_code_warning
      success_with_object(:product, @product, warning: offer_code_warning)
    else
      success_with_product(@product)
    end
  end

  def disable
    return success_with_product(@product) if @product.unpublish!

    error_with_product(@product)
  end

  def enable
    return error_with_product(@product) unless @product.validate_product_price_against_all_offer_codes?

    begin
      @product.publish!
    rescue Link::LinkInvalid
      return error_with_product(@product)
    rescue => e
      ErrorNotifier.notify(e)
      return render_response(false, message: "Something broke. We're looking into what happened. Sorry about this!")
    end

    success_with_product(@product)
  end

  def destroy
    success_with_product if @product.delete!
  end

  private
    def success_with_product(product = nil)
      success_with_object(:product, product)
    end

    def error_with_product(product = nil)
      error_with_object(:product, product)
    end

    def check_types_of_file_objects
      return if params[:file].class != String && params[:preview].class != String

      render_response(false, message: "You entered the name of the file to be uploaded incorrectly. Please refer to " \
                                      "https://gumroad.com/api#methods for the correct syntax.")
    end

    def set_link_id_to_id
      params[:link_id] = params[:id]
    end

    def validate_file_embed_conflicts!(skip_variant_embeds: false)
      existing_file_ids = @product.alive_product_files.map(&:external_id)
      incoming_file_ids = (@normalized_files || []).filter_map { |f| f[:id] }
      removing_ids = existing_file_ids - incoming_file_ids
      return if removing_ids.empty?

      product_embed_ids = if @normalized_rich_content
        extract_file_embed_ids_from_params(@normalized_rich_content)
      else
        @product.alive_rich_contents.flat_map(&:embedded_product_file_ids_in_order).map { ObfuscateIds.encrypt(_1) }
      end

      variant_embed_ids = if skip_variant_embeds
        []
      else
        @product.alive_variants.flat_map { |v| v.alive_rich_contents.flat_map(&:embedded_product_file_ids_in_order) }.map { ObfuscateIds.encrypt(_1) }
      end

      all_embed_ids = (product_embed_ids + variant_embed_ids).uniq
      conflicting = removing_ids & all_embed_ids
      return if conflicting.empty?

      raise Link::LinkInvalid, "Cannot remove files still referenced in rich content: #{conflicting.join(", ")}. Remove the file embeds from rich content first, or send both changes together."
    end

    def extract_file_embed_ids_from_params(rich_content_pages)
      return [] if rich_content_pages.blank?

      rich_content_pages.flat_map do |page|
        content = unwrap_description_content(page[:description])
        next [] if content.blank?
        extract_file_ids_from_nodes(content)
      end.compact.uniq
    end

    def extract_file_ids_from_nodes(nodes)
      nodes.flat_map do |node|
        ids = []
        if node[:type] == RichContent::FILE_EMBED_NODE_TYPE
          id = node.dig(:attrs, :id)
          ids << id if id.present?
        end
        child_content = node[:content]
        ids.concat(extract_file_ids_from_nodes(Array(child_content))) if child_content.present?
        ids
      end
    end

    def build_rich_content_params
      return [] if @normalized_rich_content.blank?

      @normalized_rich_content.flat_map { |page| unwrap_description_content(page[:description]) }
    end

    def save_rich_content!
      rich_content = @normalized_rich_content || []
      existing_rich_contents = @product.alive_rich_contents.to_a
      rich_contents_to_keep = []

      rich_content.each.with_index do |page, index|
        description_content = unwrap_description_content(page[:description])
        page_id = page[:id]
        page_title = page[:title]

        record = existing_rich_contents.find { |c| c.external_id == page_id } || @product.alive_rich_contents.build
        description_content = SaveContentUpsellsService.new(seller: @product.user, content: description_content, old_content: record.description || []).from_rich_content
        record.update!(title: page_title.presence, description: description_content.presence || [], position: index)
        rich_contents_to_keep << record
      end

      (existing_rich_contents - rich_contents_to_keep).each(&:mark_deleted!)
    end

    def migrate_rich_content_for_flag_change!
      if @product.has_same_rich_content_for_all_variants?
        migrate_to_shared_rich_content!
      else
        migrate_to_per_variant_rich_content!
      end
    end

    def migrate_to_shared_rich_content!
      variants_with_content = @product.alive_variants.select { |v| v.alive_rich_contents.any? }

      if @product.alive_rich_contents.any? && variants_with_content.any?
        raise Link::LinkInvalid, "Cannot switch to shared content: both product-level and variant-level content exist. Remove one side first, or send replacement rich_content in the same request."
      end

      if variants_with_content.length > 1
        canonical = canonicalize_rich_contents(variants_with_content.first)
        all_identical = variants_with_content.all? { |v| canonicalize_rich_contents(v) == canonical }
        if !all_identical
          raise Link::LinkInvalid, "Cannot switch to shared content: multiple variants have distinct content. Remove variant content first, or send replacement rich_content in the same request."
        end
      end

      source_variant = nil
      if @product.alive_rich_contents.empty? && variants_with_content.any?
        source_variant = variants_with_content.first
        source_variant.alive_rich_contents.sort_by(&:position).each_with_index do |rc, index|
          @product.alive_rich_contents.create!(title: rc.title, description: rc.description, position: index)
        end
      end

      @product.alive_variants.each do |variant|
        retire_upsells_from_rich_contents!(variant.alive_rich_contents) if variant != source_variant
        variant.alive_rich_contents.each(&:mark_deleted!)
        variant.product_files = []
      end
    end

    def clear_inactive_rich_content_side!
      if @product.has_same_rich_content_for_all_variants?
        clear_variant_rich_content!
      else
        retire_upsells_from_rich_contents!(@product.alive_rich_contents)
        @product.alive_rich_contents.each(&:mark_deleted!)
      end
    end

    def clear_variant_rich_content!(retire_upsells: true)
      @product.alive_variants.each do |variant|
        retire_upsells_from_rich_contents!(variant.alive_rich_contents) if retire_upsells
        variant.alive_rich_contents.each(&:mark_deleted!)
        variant.product_files = []
      end
    end

    def migrate_to_per_variant_rich_content!
      product_pages = @product.alive_rich_contents.sort_by(&:position)
      return if product_pages.empty?

      if @product.alive_variants.empty?
        raise Link::LinkInvalid, "Cannot switch to per-variant content: the product has no variants to migrate content to."
      end

      @product.alive_variants.each do |variant|
        variant.alive_rich_contents.each(&:mark_deleted!)
        variant.product_files = []

        created = product_pages.each_with_index.map do |rc, index|
          cloned_description = strip_upsell_ids(rc.description)
          cloned_description = SaveContentUpsellsService.new(
            seller: @product.user,
            content: cloned_description,
            old_content: []
          ).from_rich_content
          variant.alive_rich_contents.create!(title: rc.title, description: cloned_description, position: index)
        end

        file_ids = created.flat_map { _1.embedded_product_file_ids_in_order }.uniq
        variant.product_files = file_ids.any? ? @product.product_files.alive.where(id: file_ids) : []
      end

      retire_upsells_from_rich_contents!(product_pages)
      product_pages.each(&:mark_deleted!)
    end

    def retire_upsells_from_rich_contents!(rich_contents)
      upsell_ids = rich_contents.flat_map do |rc|
        rc.description.filter_map { |node| node["type"] == "upsellCard" ? node.dig("attrs", "id") : nil }
      end
      upsell_ids.each do |upsell_id|
        upsell = @product.user.upsells.find_by_external_id(upsell_id)
        if upsell
          upsell.offer_code&.mark_deleted!
          upsell.mark_deleted!
        end
      end
    end

    def canonicalize_rich_contents(entity)
      entity.alive_rich_contents.sort_by(&:position).map do |rc|
        [rc.title, strip_upsell_ids(rc.description)]
      end
    end

    def strip_upsell_ids_from_normalized_rich_content!
      return if @normalized_rich_content.nil?

      @normalized_rich_content = @normalized_rich_content.map do |page|
        page = page.dup
        description = unwrap_description_content(page[:description])
        page[:description] = { type: "doc", content: strip_upsell_ids(description) }
        page
      end
    end

    def strip_upsell_ids(description)
      description.map do |node|
        if node["type"] == "upsellCard" && node.dig("attrs", "id").present?
          node = node.deep_dup
          node["attrs"].delete("id")
        end
        node
      end
    end

    def check_offer_code_validity
      offer_codes = @product.product_and_universal_offer_codes
      invalid_currency_offer_codes = offer_codes.reject { |oc| oc.is_currency_valid?(@product) }.map(&:code)
      invalid_amount_offer_codes = offer_codes.reject { _1.is_amount_valid?(@product) }.map(&:code)
      all_invalid = (invalid_currency_offer_codes + invalid_amount_offer_codes).uniq
      return nil if all_invalid.empty?

      has_currency = invalid_currency_offer_codes.any?
      has_amount = invalid_amount_offer_codes.any?

      issue = if has_currency && has_amount
        "#{all_invalid.count > 1 ? "have" : "has"} currency mismatches or would discount this product below #{@product.min_price_formatted}"
      elsif has_currency
        "#{all_invalid.count > 1 ? "have" : "has"} currency #{"mismatch".pluralize(all_invalid.count)} with this product"
      else
        "#{all_invalid.count > 1 ? "discount" : "discounts"} this product below #{@product.min_price_formatted}"
      end

      "The following offer #{"code".pluralize(all_invalid.count)} #{issue}: #{all_invalid.join(", ")}. Please update #{all_invalid.length > 1 ? "them or they" : "it or it"} will not work at checkout."
    end
end
