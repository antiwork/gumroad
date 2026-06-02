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

  RESULTS_PER_PAGE = 10
  MISSING_BUY_AFFORDANCE_WARNING = "The custom landing page does not include a buy element, so buyers may not be able to purchase this product. " \
                                   'Add an element with data-gumroad-action="buy" or post a gumroad:checkout message.'

  SHOW_PRODUCT_ASSOCIATIONS = (BASE_PRODUCT_ASSOCIATIONS + [
    :page,
    :ordered_alive_product_files,
    :seller_profile_sections,
    :alive_rich_contents,
    { variant_categories_alive: [{ alive_variants: :alive_rich_contents }] },
  ]).freeze

  before_action(only: [:show, :index]) { doorkeeper_authorize!(*Doorkeeper.configuration.public_scopes.concat([:view_public])) }
  before_action(only: [:create, :update, :disable, :enable, :destroy, :preview_custom_html]) { doorkeeper_authorize! :edit_products }
  before_action :reject_unsupported_upload_fields, only: [:update, :create]
  before_action :resolve_category_param, only: [:update, :create]
  before_action :set_link_id_to_id, only: [:show, :update, :disable, :enable, :destroy, :preview_custom_html]
  before_action :fetch_product, only: [:show, :update, :disable, :enable, :destroy, :preview_custom_html]

  def index
    products = current_resource_owner.products.visible.includes(
      *INDEX_PRODUCT_ASSOCIATIONS
    ).order(created_at: :desc, id: :desc)

    if params[:page_key].present?
      begin
        last_record_created_at, last_record_id = decode_page_key(params[:page_key])
      rescue ArgumentError
        return error_400("Invalid page_key.")
      end
      products = products.where("(created_at < ?) OR (created_at = ? AND id < ?)", last_record_created_at, last_record_created_at, last_record_id)
    end

    paginated_products = products.limit(RESULTS_PER_PAGE + 1).to_a
    has_next_page = paginated_products.size > RESULTS_PER_PAGE
    paginated_products = paginated_products.first(RESULTS_PER_PAGE)

    as_json_options = {
      api_scopes: doorkeeper_token.scopes,
      slim: true,
      preloaded_ppp_factors: PurchasingPowerParityService.new.get_all_countries_factors(current_resource_owner),
      preloaded_categories_by_taxonomy_id: Discover::TaxonomyPresenter.new.categories_by_id_for_api
    }

    products_as_json = paginated_products.as_json(as_json_options)
    additional_response = has_next_page ? pagination_info(paginated_products.last) : {}

    render json: { success: true, products: products_as_json }.merge(additional_response)
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
      error = validate_file_urls(params[:files])
      return render_response(false, message: error) if error
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

    @product.created_via_cli = true if request_from_cli?

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

    if params.key?(:price_currency_type) && !CURRENCY_CHOICES.key?(params[:price_currency_type])
      return render_response(false, message: "'#{params[:price_currency_type]}' is not a supported currency.")
    end

    if params.key?(:custom_html) && !Feature.active?(:custom_html_pages, current_resource_owner)
      return render_response(false, message: "You do not have access to custom HTML pages.")
    end

    if params.key?(:custom_html) && !params[:custom_html].nil? && !params[:custom_html].is_a?(String)
      return render_response(false, message: "custom_html must be a string.")
    end

    if (length_error = custom_html_length_error)
      return render_response(false, message: length_error)
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
      if params[:files].any? { |f| f.key?(:modified) }
        return render_response(false, message: "'modified' is not an accepted parameter on files[]; it is an internal save-path flag.")
      end
      existing_files_by_id = @product.product_files.alive.index_by(&:external_id)
      new_files = []
      params[:files].each do |f|
        existing = f[:id].present? ? existing_files_by_id[f[:id]] : nil
        if existing
          if f[:url].blank?
            if (f.keys.map(&:to_s) - %w[id]).empty?
              f[:url] = existing.url
              f[:modified] = "false"
            else
              return render_response(false, message: "Include the canonical url returned by POST /v2/files/complete when updating fields on an existing file; an entry with only id keeps the file unchanged.")
            end
          elsif f[:url] != existing.url
            return render_response(false, message: "File URLs must reference your own uploaded files. Use the presigned upload endpoint to upload files first.")
          end
        elsif f[:url].blank?
          return render_response(false, message: "Each files entry must reference an existing file by id or include a url for a new file uploaded via POST /v2/files/complete.")
        else
          new_files << f
        end
      end
      error = validate_file_urls(new_files)
      return render_response(false, message: error) if error
    end

    if params.key?(:cover_ids)
      if !params[:cover_ids].is_a?(Array) || params[:cover_ids].any? { |id| !id.respond_to?(:to_str) }
        return render_response(false, message: "cover_ids must be an array of strings.")
      end
    end

    @normalized_files = normalize_params_recursively(params[:files]) if params.key?(:files)
    @normalized_rich_content = normalize_params_recursively(params[:rich_content]) if params.key?(:rich_content)

    if @normalized_files.present? && @normalized_files.any? { |f| !f.respond_to?(:key?) }
      return render_response(false, message: "files must be an array of file objects.")
    end

    if @normalized_rich_content.present? && @normalized_rich_content.any? { |p| !p.respond_to?(:key?) }
      return render_response(false, message: "rich_content must be an array of content page objects.")
    end

    previous_custom_html = nil
    sanitization_report = nil
    begin
      ActiveRecord::Base.transaction do
        # Lock the product row so concurrent custom_html PUTs serialize their
        # build_page calls — otherwise they race against the pages unique index.
        # Must precede assign_attributes — lock! raises on a dirty record. lock!
        # reloads the row, which also swaps in a fresh (empty) association cache,
        # so the previous_custom_html read below reflects a concurrent writer's
        # committed page rather than one cached before the lock.
        @product.lock! if params.key?(:custom_html)

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

        rich_content_flag_was = @product.has_same_rich_content_for_all_variants?

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

        if params.key?(:custom_html)
          previous_custom_html = @product.custom_html
          if params[:custom_html].blank?
            @product.custom_html = nil
            sanitization_report = Ai::PageSanitizer.empty_report
          else
            result = Ai::PageSanitizer.sanitize_with_report(params[:custom_html])
            @product.custom_html = result.html.presence
            sanitization_report = result.report
          end
        end

        flag_changed = @product.has_same_rich_content_for_all_variants? != rich_content_flag_was

        unless @normalized_files.nil?
          referenced_existing_ids = @normalized_files.filter_map { |f| f[:id] if f[:id].present? }
          if referenced_existing_ids.any?
            locked_alive_ids = @product.product_files.alive.lock.map(&:external_id)
            missing_ids = referenced_existing_ids - locked_alive_ids
            raise Link::LinkInvalid, "File(s) #{missing_ids.join(', ')} no longer exist; they may have been deleted by a concurrent request. Retry with the current file list." if missing_ids.any?
          end

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
    rescue ActiveModel::RangeError
      return render_response(false, message: "One or more numeric values are out of range.")
    end

    additional_info = params.key?(:custom_html) ? { previous_custom_html: previous_custom_html, sanitization_report: sanitization_report } : {}
    warnings = [check_offer_code_validity]
    if params[:custom_html].present?
      # Profiles share the sanitizer, so buy-affordance warnings stay in the product API.
      warnings << custom_html_buy_affordance_warning(@product.custom_html)
    end
    warning = warnings.compact.join(" ").presence
    additional_info[:warning] = warning if warning
    success_with_object(:product, @product, additional_info)
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

  # Dry-run sanitize: returns what `custom_html` would look like after the
  # sanitizer runs, without writing. Lets agents iterate on prompts without
  # rewriting the live page every attempt. Mirrors `update`'s blank-to-nil
  # normalization so the dry-run and the real PUT agree on edge cases like
  # input that sanitizes entirely to an empty string.
  def preview_custom_html
    return render_response(false, message: "You do not have access to custom HTML pages.") unless Feature.active?(:custom_html_pages, current_resource_owner)
    return render_response(false, message: "custom_html is required.") unless params.key?(:custom_html)

    custom_html = params[:custom_html]
    return render_response(false, message: "custom_html must be a string.") unless custom_html.nil? || custom_html.is_a?(String)

    if (length_error = custom_html_length_error)
      return render_response(false, message: length_error)
    end

    result = Ai::PageSanitizer.sanitize_with_report(custom_html)
    sanitized = result.html.presence
    candidate_page = Page.new(pageable: @product, custom_html: sanitized)
    candidate_page.validate
    errors = candidate_page.errors.where(:custom_html)

    if errors.any?
      render_response(false, message: errors.map(&:full_message).to_sentence, sanitization_report: result.report)
    else
      additional_info = { custom_html: sanitized, sanitization_report: result.report }
      warning = custom_html_buy_affordance_warning(sanitized)
      additional_info[:warning] = warning if warning
      render_response(true, additional_info)
    end
  end

  private
    def success_with_product(product = nil)
      success_with_object(:product, product)
    end

    def error_with_product(product = nil)
      error_with_object(:product, product)
    end

    def custom_html_buy_affordance_warning(html)
      return unless Pages::BuyAffordance.missing?(html)

      MISSING_BUY_AFFORDANCE_WARNING
    end

    # Reject oversized HTML before the sanitizer parses it. Page validates the
    # same 500 KB cap, but only after Nokogiri has parsed the whole payload — a
    # cheap length check first bounds CPU on the rate-limited agent path.
    def custom_html_length_error
      value = params[:custom_html]
      return unless value.is_a?(String) && value.length > Page::MAX_CUSTOM_HTML_LENGTH

      "custom_html is too long (maximum is #{Page::MAX_CUSTOM_HTML_LENGTH} characters)."
    end

    UNSUPPORTED_UPLOAD_FIELDS = %i[file preview thumbnail].freeze

    def reject_unsupported_upload_fields
      rejected_field = UNSUPPORTED_UPLOAD_FIELDS.find { |key| legacy_upload_present?(params[key]) }
      return unless rejected_field

      render_response(false, message: unsupported_upload_field_message(rejected_field))
    end

    def legacy_upload_present?(value)
      return false if value.blank?

      case value
      when ActionController::Parameters, Hash
        value.each_value.any? { |v| legacy_upload_present?(v) }
      when Array
        value.any? { |v| legacy_upload_present?(v) }
      else
        true
      end
    end

    def unsupported_upload_field_message(field)
      verb_path = action_name == "create" ? "POST /v2/products" : "PUT /v2/products/:id"
      "'#{field}' is not an accepted parameter on #{verb_path}. #{upload_field_guidance(field)}"
    end

    def upload_field_guidance(field)
      case field
      when :file
        presign_flow = "Upload files with the presign flow (POST /v2/files/presign, upload parts to the returned S3 URLs, then POST /v2/files/complete), then attach them by including the returned URLs in files[][url]."
        if action_name == "create"
          presign_flow
        else
          "#{presign_flow} Note: files is a full replacement — to keep an existing file, include an entry with its id; files missing from the array are removed."
        end
      when :preview
        if action_name == "create"
          "Covers can only be added after the product is created. Create the product first, then POST to /v2/products/:id/covers with a url or signed_blob_id."
        else
          "Use POST /v2/products/:id/covers with a url or signed_blob_id to add a cover."
        end
      when :thumbnail
        if action_name == "create"
          "Thumbnails can only be set after the product is created. Create the product first, then POST to /v2/products/:id/thumbnail with a signed_blob_id."
        else
          "Use POST /v2/products/:id/thumbnail with a signed_blob_id to set the thumbnail."
        end
      end
    end

    def validate_file_urls(files)
      if files.any? { |f| !f[:url].respond_to?(:to_str) || f[:url].blank? }
        return "Each file must include a url string."
      end
      seller_s3_prefix = "#{S3_BASE_URL}attachments/#{current_resource_owner.external_id}/"
      if files.any? { |f| !f[:url].start_with?(seller_s3_prefix) || f[:url].include?("..") || f[:url].include?("%2F") || f[:url].include?("%2f") }
        return "File URLs must reference your own uploaded files. Use the presigned upload endpoint to upload files first."
      end
      nil
    end

    def resolve_category_param
      if params.key?(:category)
        if params[:category].respond_to?(:key?) || params[:category].is_a?(Array)
          return render_response(false, message: "category must be a scalar value.")
        end

        if params[:category].present?
          if params[:taxonomy_id].present?
            return render_response(false, message: "Specify either category or taxonomy_id, not both.")
          end

          category = Discover::TaxonomyPresenter.new.category_for_path(params[:category].to_s)
          return render_response(false, message: "Invalid category.") if category.blank?

          params[:taxonomy_id] = category[:id]
          return validate_taxonomy_id_param(invalid_message: "Invalid category.")
        end
      end

      validate_taxonomy_id_param
    end

    def validate_taxonomy_id_param(invalid_message: "Invalid taxonomy_id.")
      return if params[:taxonomy_id].blank?

      if params[:taxonomy_id].respond_to?(:key?) || params[:taxonomy_id].is_a?(Array)
        return render_response(false, message: "taxonomy_id must be a scalar value.")
      end
      if !Taxonomy.exists?(params[:taxonomy_id])
        render_response(false, message: invalid_message)
      end
    rescue ActiveModel::RangeError
      render_response(false, message: "One or more numeric values are out of range.")
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

      removed = existing_rich_contents - rich_contents_to_keep
      retire_upsells_from_rich_contents!(removed)
      removed.each(&:mark_deleted!)
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
