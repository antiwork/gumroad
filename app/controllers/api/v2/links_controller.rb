# frozen_string_literal: true

class Api::V2::LinksController < Api::V2::BaseController
  BASE_PRODUCT_ASSOCIATIONS = [
    :preorder_link, :tags, :taxonomy,
    { display_asset_previews: [:file_attachment, :file_blob] },
    { bundle_products: [:product, :variant] },
  ].freeze

  INDEX_PRODUCT_ASSOCIATIONS = (BASE_PRODUCT_ASSOCIATIONS + [
    { variant_categories_alive: [:alive_variants] },
  ]).freeze

  SHOW_PRODUCT_ASSOCIATIONS = (BASE_PRODUCT_ASSOCIATIONS + [
    :ordered_alive_product_files,
    :alive_rich_contents,
    { variant_categories_alive: [{ alive_variants: :alive_rich_contents }] },
  ]).freeze

  before_action(only: [:show, :index]) { doorkeeper_authorize!(*Doorkeeper.configuration.public_scopes.concat([:view_public])) }
  before_action(only: [:create, :update, :disable, :enable, :destroy]) { doorkeeper_authorize! :edit_products }
  before_action :check_types_of_file_objects, only: [:update, :create]
  before_action :set_link_id_to_id, only: [:show, :update, :disable, :enable, :destroy]
  before_action :fetch_product, only: [:show, :update, :disable, :enable, :destroy]

  def index
    products = current_resource_owner.products.visible.includes(
      *INDEX_PRODUCT_ASSOCIATIONS
    ).order(created_at: :desc)

    as_json_options = {
      api_scopes: doorkeeper_token.scopes,
      slim: true,
      preloaded_ppp_factors: PurchasingPowerParityService.new.get_all_countries_factors(current_resource_owner)
    }

    products_as_json = products.as_json(as_json_options)

    render json: { success: true, products: products_as_json }
  end

  def create
    native_type = params[:native_type].presence || Link::NATIVE_TYPE_DIGITAL

    unsupported_types = Link::LEGACY_TYPES + [Link::NATIVE_TYPE_PHYSICAL]
    if unsupported_types.include?(native_type)
      return render_response(false, message: "The product type '#{native_type}' is not supported for creation.")
    end

    if native_type == Link::NATIVE_TYPE_COMMISSION && !Feature.active?(:commissions, current_resource_owner)
      return render_response(false, message: "You do not have access to create commission products.")
    end

    if params[:subscription_duration].present?
      if !Link.subscription_durations.key?(params[:subscription_duration])
        return render_response(false, message: "Invalid subscription duration '#{params[:subscription_duration]}'. Valid values: #{Link.subscription_durations.keys.join(', ')}.")
      end
      if native_type != Link::NATIVE_TYPE_MEMBERSHIP
        return render_response(false, message: "subscription_duration is only valid for membership products.")
      end
    end

    currency = params[:price_currency_type].presence || current_resource_owner.currency_type
    if !CURRENCY_CHOICES.key?(currency)
      return render_response(false, message: "'#{currency}' is not a supported currency.")
    end

    if params.key?(:tags)
      if !params[:tags].is_a?(Array) || params[:tags].any? { |t| !t.respond_to?(:to_str) }
        return render_response(false, message: "tags must be an array of strings.")
      end
    end

    if params.key?(:rich_content)
      if !params[:rich_content].is_a?(Array) || params[:rich_content].any? { |p| !p.respond_to?(:key?) }
        return render_response(false, message: "rich_content must be an array of content page objects.")
      end
      params[:rich_content].each do |p|
        desc = p[:description]
        next if desc.blank?
        if !desc.respond_to?(:key?) && !desc.is_a?(Array)
          return render_response(false, message: "Each rich_content page description must be a JSON object or array.")
        end
        content_nodes = if desc.respond_to?(:key?)
          if desc[:content].present? && !desc[:content].is_a?(Array)
            return render_response(false, message: "rich_content description content must be an array.")
          end
          desc[:content]
        else
          desc
        end
        if content_nodes.is_a?(Array) && content_nodes.any? { |n| !n.respond_to?(:key?) }
          return render_response(false, message: "Each rich_content content node must be a JSON object.")
        end
      end
    end

    if params.key?(:files)
      if !params[:files].is_a?(Array) || params[:files].any? { |f| !f.respond_to?(:key?) }
        return render_response(false, message: "files must be an array of file objects.")
      end
      if params[:files].any? { |f| !f[:url].respond_to?(:to_str) || f[:url].blank? }
        return render_response(false, message: "Each file must include a url string.")
      end
      seller_s3_prefix = "#{S3_BASE_URL}attachments/#{current_resource_owner.external_id}/"
      if params[:files].any? { |f| !f[:url].start_with?(seller_s3_prefix) || f[:url].include?("..") || f[:url].include?("%2F") || f[:url].include?("%2f") }
        return render_response(false, message: "File URLs must reference your own uploaded files. Use the presigned upload endpoint to upload files first.")
      end
    end

    if params[:taxonomy_id].present?
      if params[:taxonomy_id].respond_to?(:key?) || params[:taxonomy_id].is_a?(Array)
        return render_response(false, message: "taxonomy_id must be a scalar value.")
      end
      if !Taxonomy.exists?(params[:taxonomy_id])
        return render_response(false, message: "Invalid taxonomy_id.")
      end
    end

    is_recurring_billing = native_type == Link::NATIVE_TYPE_MEMBERSHIP
    is_bundle = native_type == Link::NATIVE_TYPE_BUNDLE

    @product = current_resource_owner.links.build(create_permitted_params)
    @product.native_type = native_type
    @product.subscription_duration = params[:subscription_duration] if is_recurring_billing && params[:subscription_duration].present?
    @product.is_recurring_billing = is_recurring_billing
    @product.is_bundle = is_bundle
    @product.price_cents = params[:price] if params.key?(:price)
    @product.price_currency_type = currency
    @product.draft = true
    @product.purchase_disabled_at = Time.current
    @product.display_product_reviews = true
    @product.is_tiered_membership = is_recurring_billing
    @product.should_show_all_posts = @product.is_tiered_membership
    @product.should_include_last_post = true if Product::NativeTypeTemplates::PRODUCT_TYPES_THAT_INCLUDE_LAST_POST.include?(native_type)
    @product.taxonomy = Taxonomy.find_by(slug: "other") if params[:taxonomy_id].blank?
    @product.json_data["custom_button_text_option"] = "donate_prompt" if native_type == Link::NATIVE_TYPE_COFFEE

    if params[:custom_summary].present?
      @product.json_data["custom_summary"] = params[:custom_summary]
    end

    ActiveRecord::Base.transaction do
      @product.save!
      @product.set_template_properties_if_needed

      if params.key?(:description)
        @product.description = SaveContentUpsellsService.new(seller: @product.user, content: @product.description, old_content: nil).from_html
        @product.save!
      end

      @product.save_tags!(params[:tags]) if params.key?(:tags)

      if params.key?(:files)
        rich_content_params = extract_rich_content_params
        file_params = ActionController::Parameters.new(files: params[:files]).permit(files: [:id, :url, :display_name, :extension, :position, :stream_only, :description])
        SaveFilesService.perform(@product, file_params, rich_content_params)
        @product.save!
      end

      if params.key?(:rich_content)
        permitted_rich_content = params[:rich_content].map do |p|
          page = { id: p[:id], title: p[:title] }
          page[:description] = p[:description] if p[:description].respond_to?(:key?) || p[:description].is_a?(Array)
          page.with_indifferent_access
        end
        process_rich_content(@product, permitted_rich_content)
        Product::SavePostPurchaseCustomFieldsService.new(@product).perform
        @product.is_licensed = @product.has_embedded_license_key?
        @product.is_multiseat_license = false if !@product.is_licensed
        @product.save!
      end

      @product.generate_product_files_archives! if params.key?(:files)
    end

    success_with_product(@product.reload)
  rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid => e
    if e.respond_to?(:record) && e.record != @product
      render_response(false, message: e.record.errors.full_messages.to_sentence)
    else
      error_with_creating_object(:product, @product)
    end
  rescue Link::LinkInvalid
    error_with_creating_object(:product, @product)
  rescue ActiveModel::RangeError
    render_response(false, message: "One or more numeric values are out of range.")
  end

  def show
    ActiveRecord::Associations::Preloader.new(records: [@product], associations: SHOW_PRODUCT_ASSOCIATIONS).call
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
        @product.assign_attributes(attrs)

        if params.key?(:description)
          @product.description = SaveContentUpsellsService.new(seller: @product.user, content: params[:description], old_content: @product.description_was).from_html
        end

        if params.key?(:custom_summary)
          @product.json_data["custom_summary"] = params[:custom_summary]
        end

        unless @normalized_files.nil?
          validate_file_embed_conflicts!

          rich_content_params = build_rich_content_params
          SaveFilesService.perform(@product, { files: @normalized_files }, rich_content_params)
        end

        @product.save!

        @product.save_tags!(params[:tags]) if params.key?(:tags)

        if params.key?(:cover_ids)
          cover_ids = normalize_params_recursively(params[:cover_ids])
          @product.reorder_previews(cover_ids.map.with_index.to_h)
        end

        unless @normalized_rich_content.nil?
          save_rich_content!
          Product::SavePostPurchaseCustomFieldsService.new(@product).perform
          @product.is_licensed = @product.has_embedded_license_key?
          @product.is_multiseat_license = false if !@product.is_licensed
          @product.save!
        end

        @product.generate_product_files_archives! if !@normalized_files.nil? || !@normalized_rich_content.nil?
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
    rescue Link::LinkInvalid, ActiveRecord::RecordInvalid
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

    def create_permitted_params
      params.permit(
        :name, :description, :custom_permalink, :max_purchase_count,
        :customizable_price, :suggested_price_cents, :taxonomy_id
      )
    end

    def extract_rich_content_params
      return [] if !params.key?(:rich_content)

      rich_content = params[:rich_content]
      return [] if rich_content.blank?

      [*rich_content].flat_map { |page| page[:description].is_a?(Hash) ? page[:description][:content] : page[:description] }.compact
    end

    def process_rich_content(product, rich_content_array)
      return if rich_content_array.blank?

      existing_rich_contents = product.alive_rich_contents.to_a
      rich_contents_to_keep = []

      rich_content_array.each.with_index do |page, index|
        page = page.with_indifferent_access
        rich_content = existing_rich_contents.find { |c| c.external_id == page[:id] } || product.alive_rich_contents.build
        description = page[:description].respond_to?(:key?) ? page[:description][:content] : page[:description]
        description = Array.wrap(description)
        description = SaveContentUpsellsService.new(
          seller: product.user,
          content: description,
          old_content: rich_content.description || []
        ).from_rich_content
        rich_content.update!(title: page[:title].presence, description: description.presence || [], position: index)
        rich_contents_to_keep << rich_content
      end

      (existing_rich_contents - rich_contents_to_keep).each(&:mark_deleted!)
    end

    def normalize_params_recursively(obj)
      case obj
      when ActionController::Parameters
        normalize_params_recursively(obj.to_unsafe_h)
      when Hash
        if obj.keys.all? { |k| k.to_s.match?(/\A\d+\z/) }
          obj.sort_by { |k, _| k.to_i }.map { |_, v| normalize_params_recursively(v) }
        else
          obj.transform_values { |v| normalize_params_recursively(v) }.with_indifferent_access
        end
      when Array
        obj.map { |v| normalize_params_recursively(v) }
      else
        obj
      end
    end

    def validate_file_embed_conflicts!
      existing_file_ids = @product.alive_product_files.map(&:external_id)
      incoming_file_ids = (@normalized_files || []).filter_map { |f| f[:id] }
      removing_ids = existing_file_ids - incoming_file_ids
      return if removing_ids.empty?

      product_embed_ids = if @normalized_rich_content
        extract_file_embed_ids_from_params(@normalized_rich_content)
      else
        @product.alive_rich_contents.flat_map(&:embedded_product_file_ids_in_order).map { ObfuscateIds.encrypt(_1) }
      end

      variant_embed_ids = @product.alive_variants.flat_map { |v| v.alive_rich_contents.flat_map(&:embedded_product_file_ids_in_order) }.map { ObfuscateIds.encrypt(_1) }

      all_embed_ids = (product_embed_ids + variant_embed_ids).uniq
      conflicting = removing_ids & all_embed_ids
      return if conflicting.empty?

      raise Link::LinkInvalid, "Cannot remove files still referenced in rich content: #{conflicting.join(", ")}. Remove the file embeds from rich content first, or send both changes together."
    end

    def unwrap_description_content(description)
      if description.respond_to?(:key?) && description.key?(:content)
        description[:content] || []
      else
        Array(description)
      end
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
