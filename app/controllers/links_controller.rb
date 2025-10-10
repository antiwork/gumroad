# frozen_string_literal: true

class LinksController < ApplicationController
  include ProductsHelper, SearchProducts, PreorderHelper, ActionView::Helpers::TextHelper,
          ActionView::Helpers::AssetUrlHelper, CustomDomainConfig, AffiliateCookie,
          CreateDiscoverSearch, DiscoverCuratedProducts, FetchProductByUniquePermalink

  DEFAULT_PRICE = 500
  PER_PAGE = 50

  skip_before_action :check_suspended, only: %i[index show edit destroy increment_views track_user_action]

  PUBLIC_ACTIONS = %i[show search increment_views track_user_action cart_items_count].freeze
  before_action :authenticate_user!, except: PUBLIC_ACTIONS
  after_action :verify_authorized, except: PUBLIC_ACTIONS

  before_action :fetch_product_for_show, only: :show
  before_action :check_banned, only: :show
  before_action :set_x_robots_tag_header, only: :show
  before_action :check_payment_details, only: :index

  before_action :set_affiliate_cookie, only: [:show]

  before_action :hide_layouts, only: %i[show]
  before_action :fetch_product, only: %i[increment_views track_user_action]
  before_action :ensure_seller_is_not_deleted, only: [:show]
  before_action :check_if_needs_redirect, only: [:show]
  before_action :prepare_product_page, only: %i[show]
  before_action :set_frontend_performance_sensitive, only: %i[show]
  before_action :ensure_domain_belongs_to_seller, only: [:show]
  before_action :fetch_product_and_enforce_ownership, only: %i[destroy]
  before_action :fetch_product_and_enforce_access, only: %i[update publish unpublish release_preorder update_sections]

  layout "inertia", only: [:index]

  def index
    authorize Link

    @guid = SecureRandom.hex
    @title = "Products"

    @memberships_pagination, @memberships = paginated_memberships(page: 1)
    @products_pagination, @products = paginated_products(page: 1)

    @price = current_seller.links.last.try(:price_formatted_without_dollar_sign) ||
             Money.new(DEFAULT_PRICE, current_seller.currency_type).format(
               no_cents_if_whole: true, symbol: false
             )

    @user_compliance_info = current_seller.fetch_or_build_user_compliance_info
    @react_products_page_props = DashboardProductsPagePresenter.new(
      pundit_user:,
      memberships: @memberships,
      memberships_pagination: @memberships_pagination,
      products: @products,
      products_pagination: @products_pagination
    ).page_props

    render inertia: "Products/index",
           props: { react_products_page_props: @react_products_page_props }
  end

  def memberships_paged
    authorize Link, :index?

    pagination, memberships = paginated_memberships(page: paged_params[:page].to_i, query: params[:query])
    react_products_page_props = DashboardProductsPagePresenter.new(
      pundit_user:,
      memberships:,
      memberships_pagination: pagination,
      products: nil,
      products_pagination: nil)
    .memberships_table_props

    render json: {
      pagination: react_products_page_props[:memberships_pagination],
      entries: react_products_page_props[:memberships]
    }
  end

  def products_paged
    authorize Link, :index?

    pagination, products = paginated_products(page: paged_params[:page].to_i, query: params[:query])
    react_products_page_props = DashboardProductsPagePresenter.new(
      pundit_user:,
      memberships: nil,
      memberships_pagination: nil,
      products:,
      products_pagination: pagination
    ).products_table_props

    render json: {
      pagination: react_products_page_props[:products_pagination],
      entries: react_products_page_props[:products]
    }
  end

  def new
    authorize Link

    @react_new_product_page_props = ProductPresenter.new_page_props(current_seller:)
    @title = "What are you creating?"
  end

  def create
    authorize Link

    if params[:link][:is_physical]
      return head :forbidden unless current_seller.can_create_physical_products?
      params[:link][:quantity_enabled] = true
    end

    @product = current_seller.links.build(link_params)

    @product.price_range = params[:link][:price_range]

    @product.save_custom_summary(params[:link][:custom_summary]) if params[:link][:custom_summary].present?
    @product.draft = true
    @product.purchase_disabled_at = Time.current
    @product.require_shipping = true if @product.is_physical
    @product.display_product_reviews = true
    @product.is_tiered_membership = @product.is_recurring_billing
    @product.should_show_all_posts = @product.is_tiered_membership
    @product.set_template_properties_if_needed
    @product.taxonomy = Taxonomy.find_by(slug: "other")
    @product.is_bundle = @product.native_type == Link::NATIVE_TYPE_BUNDLE
    @product.json_data[:custom_button_text_option] = "donate_prompt" if @product.native_type == Link::NATIVE_TYPE_COFFEE

    begin
      @product.save!

      if params[:link][:ai_prompt].present? && Feature.active?(:ai_product_generation, current_seller)
        generate_product_details_using_ai
      end
    rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid
      @error_message = if @product&.errors&.any?
        @product.errors.full_messages.first
      elsif @preorder_link&.errors&.any?
        @preorder_link.errors.full_messages[0]
      else
        "Sorry, something went wrong."
      end
      return respond_to do |format|
        response = { success: false, error_message: @error_message }
        format.json { render json: response }
        format.html { render html: "<textarea>#{response.to_json}</textarea>" }
      end
    end

    create_user_event("add_product")
    respond_to do |format|
      response = { success: true, redirect_to: edit_link_path(@product) }
      format.html { render plain: response.to_json.to_s }
      format.json { render json: response }
    end
  end

  def show
    return redirect_to custom_domain_coffee_path if @product.native_type == Link::NATIVE_TYPE_COFFEE
    ActiveRecord::Base.connection.stick_to_primary!
    # Force a preload of all association data used in rendering
    preload_product
    @show_user_favicon = true

    if params[:wanted] == "true"
      params[:option] ||= params[:variant] && @product.options.find { |o| o[:name] == params[:variant] }&.[](:id)
      BasePrice::Recurrence::ALLOWED_RECURRENCES.each do |r|
        params[:recurrence] ||= r if params[r] == "true"
      end
      params[:price] = (params[:price].to_f * 100).to_i if params[:price].present?
      cart_item = @product.cart_item(params)

      unless (@product.customizable_price || cart_item[:option]&.[](:is_pwyw)) &&
             (params[:price].blank? || params[:price] < cart_item[:price])
        redirect_to checkout_index_url(**params.permit!, host: DOMAIN, product: @product.unique_permalink,
                                                         rent: cart_item[:rental], recurrence: cart_item[:recurrence],
                                                         price: cart_item[:price],
                                                         code: params[:offer_code] || params[:code],
                                                         affiliate_id: params[:affiliate_id] || params[:a],
                                                         referrer: params[:referrer] || request.referrer),
                    allow_other_host: true
      end
    end

    @card_data_handling_mode = CardDataHandlingMode.get_card_data_handling_mode(@product.user)
    @paypal_merchant_currency = @product.user.native_paypal_payment_enabled? ?
                                  @product.user.merchant_account_currency(PaypalChargeProcessor.charge_processor_id) :
                                  ChargeProcessor::DEFAULT_CURRENCY_CODE
    @pay_with_card_enabled = @product.user.pay_with_card_enabled?
    presenter = ProductPresenter.new(pundit_user:, product: @product, request:)
    presenter_props = { recommended_by: params[:recommended_by], discount_code: params[:offer_code] || params[:code], quantity: (params[:quantity] || 1).to_i, layout: params[:layout], seller_custom_domain_url: }
    @product_props = params[:embed] || params[:overlay] ? presenter.product_props(**presenter_props) : presenter.product_page_props(**presenter_props)
    @body_class = "iframe" if params[:overlay] || params[:embed]

    if ["search", "discover"].include?(params[:recommended_by])
      create_discover_search!(
        clicked_resource: @product,
        query: params[:query],
        autocomplete: params[:autocomplete] == "true"
      )
    end

    if params[:layout] == Product::Layout::DISCOVER
      @discover_props = { taxonomy_path: @product.taxonomy&.ancestry_path&.join("/"), taxonomies_for_nav: }
    end

    set_noindex_header if !@product.alive?
    respond_to do |format|
      format.html
      format.json { render json: @product.as_json }
      format.any { e404 }
    end
  end

  def cart_items_count
    @hide_layouts = true
    @disable_third_party_analytics = true
  end

  def search
    search_params = params
    on_profile = search_params[:user_id].present?
    if on_profile
      user = User.find_by_external_id(search_params[:user_id])
      section = user && user.seller_profile_products_sections.on_profile.find_by_external_id(search_params[:section_id])
      return render json: { total: 0, filetypes_data: [], tags_data: [], products: [] } if section.nil?
      search_params[:section] = section
      search_params[:is_alive_on_profile] = true
      search_params[:user_id] = user.id
      search_params[:sort] = section.default_product_sort if search_params[:sort].nil?
      search_params[:sort] = ProductSortKey::PAGE_LAYOUT if search_params[:sort] == "default"
      search_params[:ids]&.map! { ObfuscateIds.decrypt(_1) }
    else
      search_params[:sort] = ProductSortKey::FEATURED if search_params[:sort] == "default"
      search_params[:include_rated_as_adult] = logged_in_user&.show_nsfw_products?
      search_params[:curated_product_ids] = params[:curated_product_ids]&.map { ObfuscateIds.decrypt(_1) }
    end

    if search_params[:taxonomy].present?
      search_params[:taxonomy_id] = Taxonomy.find_by_path(params[:taxonomy].split("/"))&.id
      search_params[:include_taxonomy_descendants] = true
    end

    if on_profile
      recommended_by = search_params[:recommended_by]
    else
      recommended_by = RecommendationType::GUMROAD_SEARCH_RECOMMENDATION
      create_discover_search!(query: search_params[:query], taxonomy_id: search_params[:taxonomy_id])
    end

    results = search_products(search_params)
    results[:products] = results[:products].includes(ProductPresenter::ASSOCIATIONS_FOR_CARD).map do |product|
      ProductPresenter.card_for_web(
        product:,
        request:,
        recommended_by:,
        target: on_profile ? Product::Layout::PROFILE : Product::Layout::DISCOVER,
        show_seller: !on_profile,
        query: (search_params[:query] unless on_profile)
      )
    end
    render json: results
  end

  def check_if_needs_redirect
    # If the request is for the product's custom domain, don't redirect
    return if product_by_custom_domain.present?

    # Else, redirect to the creator's subdomain, if it exists.
    # E.g., we want to redirect gumroad.com/l/id to username.gumroad.com/l/id
    creator_subdomain_with_protocol = @product.user.subdomain_with_protocol
    target_host = !@is_user_custom_domain && creator_subdomain_with_protocol.present? ? creator_subdomain_with_protocol : request.host
    target_permalink = @product.general_permalink

    searched_id = params[:id] || params[:link_id]

    if target_host != request.host || target_permalink != searched_id
      target_product_url = if params[:code].present?
        short_link_offer_code_url(target_permalink, code: params[:code], host: target_host, format: params[:format])
      else
        short_link_url(target_permalink, host: target_host, format: params[:format])
      end

      # Attaching raw query string to the redirect URL to preserve the original encoding in the request.
      # For example, we use '%20' instead of '+' in query string when the variant name contains space.
      # If we use request.query_parameters while redirecting, it would convert '%20' to '+' which would break
      # variant auto selection.
      query_string = "?#{request.query_string}" if request.query_string.present?

      redirect_to "#{target_product_url}#{query_string}", status: :moved_permanently, allow_other_host: true
    end
  end

  def set_x_robots_tag_header
    set_noindex_header  if params[:code].present?
  end

  def increment_views
    skip = is_bot?
    skip |= logged_in_user.present? && (@product.user_id == current_seller.id || logged_in_user.is_team_member?)
    skip |= impersonating_user&.id

    unless skip
      create_product_page_view(
        user_id: logged_in_user&.id,
        referrer: Array.wrap(params[:referrer]).compact_blank.last || request.referrer,
        was_product_recommended: ActiveModel::Type::Boolean.new.cast(params[:was_product_recommended]),
        view_url: params[:view_url] || request.env["PATH_INFO"]
      )
    end

    render json: { success: true }
  end

  def track_user_action
    create_user_event(params[:event_name]) unless logged_in_user == @product.user
    render json: { success: true }
  end

  def edit
    fetch_product_by_unique_permalink
    authorize @product

    redirect_to bundle_path(@product.external_id) if @product.is_bundle?

    @title = @product.name

    @presenter = ProductPresenter.new(product: @product, pundit_user:)
  end

  def update
    authorize @product
    begin
      ActiveRecord::Base.transaction do
        @product.assign_attributes(product_permitted_params.except(
          :products,
          :description,
          :cancellation_discount,
          :custom_button_text_option,
          :custom_summary,
          :custom_attributes,
          :file_attributes,
          :covers,
          :refund_policy,
          :product_refund_policy_enabled,
          :seller_refund_policy_enabled,
          :integrations,
          :variants,
          :tags,
          :section_ids,
          :availabilities,
          :custom_domain,
          :rich_content,
          :files,
          :public_files,
          :shipping_destinations,
          :call_limitation_info,
          :installment_plan,
          :community_chat_enabled
        ))
        @product.description = SaveContentUpsellsService.new(seller: @product.user, content: product_permitted_params[:description], old_content: @product.description_was).from_html
        @product.skus_enabled = false
        @product.save_custom_button_text_option(product_permitted_params[:custom_button_text_option]) unless product_permitted_params[:custom_button_text_option].nil?
        @product.save_custom_summary(product_permitted_params[:custom_summary]) unless product_permitted_params[:custom_summary].nil?
        @product.save_custom_attributes((product_permitted_params[:custom_attributes] || []).filter { _1[:name].present? || _1[:description].present? })
        @product.save_tags!(product_permitted_params[:tags] || [])
        @product.reorder_previews((product_permitted_params[:covers] || []).map.with_index.to_h)
        if !current_seller.account_level_refund_policy_enabled?
          @product.product_refund_policy_enabled = product_permitted_params[:product_refund_policy_enabled]
          if product_permitted_params[:refund_policy].present? && product_permitted_params[:product_refund_policy_enabled]
            @product.find_or_initialize_product_refund_policy.update!(product_permitted_params[:refund_policy])
          end
        end
        @product.show_in_sections!(product_permitted_params[:section_ids] || [])
        @product.save_shipping_destinations!(product_permitted_params[:shipping_destinations] || []) if @product.is_physical

        if Feature.active?(:cancellation_discounts, @product.user) && (product_permitted_params[:cancellation_discount].present? || @product.cancellation_discount_offer_code.present?)
          begin
            Product::SaveCancellationDiscountService.new(@product, product_permitted_params[:cancellation_discount]).perform
          rescue ActiveRecord::RecordInvalid => e
            return render json: { error_message: e.record.errors.full_messages.first }, status: :unprocessable_entity
          end
        end

        if @product.native_type === Link::NATIVE_TYPE_COFFEE
          @product.suggested_price_cents = product_permitted_params[:variants].map { _1[:price_difference_cents] }.max
        end

        # TODO clean this up
        rich_content = product_permitted_params[:rich_content] || []
        rich_content_params = [*rich_content]
        product_permitted_params[:variants].each { rich_content_params.push(*_1[:rich_content]) } if product_permitted_params[:variants].present?
        rich_content_params = rich_content_params.flat_map { _1[:description] = _1.dig(:description, :content) }
        rich_contents_to_keep = []
        SaveFilesService.perform(@product, product_permitted_params, rich_content_params)
        existing_rich_contents = @product.alive_rich_contents.to_a
        rich_content.each.with_index do |product_rich_content, index|
          rich_content = existing_rich_contents.find { |c| c.external_id === product_rich_content[:id] } || @product.alive_rich_contents.build
          product_rich_content[:description] = SaveContentUpsellsService.new(seller: @product.user, content: product_rich_content[:description], old_content: rich_content.description || []).from_rich_content
          rich_content.update!(title: product_rich_content[:title].presence, description: product_rich_content[:description].presence || [], position: index)
          rich_contents_to_keep << rich_content
        end
        (existing_rich_contents - rich_contents_to_keep).each(&:mark_deleted!)

        Product::SaveIntegrationsService.perform(@product, product_permitted_params[:integrations])
        update_variants
        update_removed_file_attributes
        update_custom_domain
        update_availabilities
        update_call_limitation_info
        update_installment_plan

        Product::SavePostPurchaseCustomFieldsService.new(@product).perform

        @product.is_licensed = @product.has_embedded_license_key?
        unless @product.is_licensed
          @product.is_multiseat_license = false
        end
        @product.description = SavePublicFilesService.new(resource: @product, files_params: product_permitted_params[:public_files], content: @product.description).process
        @product.save!
        toggle_community_chat!(product_permitted_params[:community_chat_enabled])
        @product.generate_product_files_archives!
      end
    rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid => e
      if @product.errors.details[:custom_fields].present?
        error_message = "You must add titles to all of your inputs"
      else
        error_message = @product.errors.full_messages.first || e.message
      end
      return render json: { error_message: }, status: :unprocessable_entity
    end
    invalid_currency_offer_codes = @product.product_and_universal_offer_codes.reject do |offer_code|
      offer_code.is_currency_valid?(@product)
    end.map(&:code)
    invalid_amount_offer_codes = @product.product_and_universal_offer_codes.reject { _1.is_amount_valid?(@product) }.map(&:code)

    all_invalid_offer_codes = (invalid_currency_offer_codes + invalid_amount_offer_codes).uniq

    if all_invalid_offer_codes.any?
      # Determine the main issue type for the message
      has_currency_issues = invalid_currency_offer_codes.any?
      has_amount_issues = invalid_amount_offer_codes.any?

      if has_currency_issues && has_amount_issues
        issue_description = "#{"has".pluralize(all_invalid_offer_codes.count)} currency mismatches or would discount this product below #{@product.min_price_formatted}"
      elsif has_currency_issues
        issue_description = "#{"has".pluralize(all_invalid_offer_codes.count)} currency #{"mismatch".pluralize(all_invalid_offer_codes.count)} with this product"
      else
        issue_description = "#{all_invalid_offer_codes.count > 1 ? "discount" : "discounts"} this product below #{@product.min_price_formatted}, but not to #{MoneyFormatter.format(0, @product.price_currency_type.to_sym, no_cents_if_whole: true, symbol: true)}"
      end

      return render json: {
        warning_message: "The following offer #{"code".pluralize(all_invalid_offer_codes.count)} #{issue_description}: #{all_invalid_offer_codes.join(", ")}. Please update #{all_invalid_offer_codes.length > 1 ? "them or they" : "it or it"} will not work at checkout."
      }
    end

    head :no_content
  end

  def unpublish
    authorize @product

    @product.unpublish!
    render json: { success: true }
  end

  def publish
    authorize @product

    if @product.user.email.blank?
      return render json: { success: false, error_message: "<span>To publish a product, we need you to have an email. <a href=\"#{settings_main_url}\">Set an email</a> to continue.</span>" }
    end

    begin
      @product.publish!
    rescue Link::LinkInvalid, ActiveRecord::RecordInvalid
      return render json: { success: false, error_message: @product.errors.full_messages[0] }
    rescue => e
      Bugsnag.notify(e)
      return render json: { success: false, error_message: "Something broke. We're looking into what happened. Sorry about this!" }
    end

    render json: { success: true }
  end

  def destroy
    authorize @product

    @product.delete!
    render json: { success: true }
  end

  def update_sections
    authorize @product
    ActiveRecord::Base.transaction do
      @product.sections = Array(params[:sections]).map! { ObfuscateIds.decrypt(_1) }
      @product.main_section_index = params[:main_section_index].to_i
      @product.save!
      @product.seller_profile_sections.where.not(id: @product.sections).destroy_all
    end
  end

  def release_preorder
    authorize @product

    preorder_link = @product.preorder_link
    preorder_link.is_being_manually_released_by_the_seller = true
    released_successfully = preorder_link.release!
    if released_successfully
      render json: { success: true }
    else
      render json: { success: false,
                     error_message: !@product.has_content? ? "Sorry, your pre-order was not released due to no file or redirect URL being specified. Please do that and try again!" : "Your pre-order was released successfully." }
    end
  end

  def send_sample_price_change_email
    fetch_product_by_unique_permalink
    authorize @product, :update?

    tier = @product.tiers.find_by_external_id(params.require(:tier_id))
    return e404_json unless tier.present?

    CustomerLowPriorityMailer.sample_subscription_price_change_notification(
      user: logged_in_user,
      tier:,
      effective_date: params[:effective_date].present? ? Date.parse(params[:effective_date]) : tier.subscription_price_change_effective_date,
      recurrence: params.require(:recurrence),
      new_price: (params.require(:amount).to_f * 100).to_i,
      custom_message: strip_tags(params[:custom_message]).present? ? params[:custom_message] : nil,
    ).deliver_later

    render json: { success: true }
  end

  private
    def fetch_product_for_show
      fetch_product_by_custom_domain || fetch_product_by_general_permalink
    end

    def fetch_product_by_custom_domain
      @product = product_by_custom_domain
    end

    # *** DO NOT USE THIS METHOD for actions that respond to non-subdomain URLs ***
    #
    # Used for actions where a product's general (custom or unique) permalink is used to identify the product.
    # Usually these are public-facing URLs with permalink as part of the URL.
    #
    # Since custom permalinks aren't globally unique, this method is only guaranteed to fetch the unique product
    # if the owner of the product can be identified by the URL's subdomain.
    #
    # To support legacy (non-subdomain) URLs, when no creator can be identify via subdomain, this method will fetch the
    # oldest product with given unique or custom permalink.
    def fetch_product_by_general_permalink
      custom_or_unique_permalink = params[:id] || params[:link_id]
      e404 if custom_or_unique_permalink.blank?

      @product = Link.fetch_leniently(custom_or_unique_permalink, user: user_by_domain(request.host)) || e404
    end

    def preload_product
      @product = Link.includes(
        :variant_categories_alive,
        :alive_prices,
        { display_asset_previews: [:file_attachment, :file_blob] },
        :alive_third_party_analytics
      ).find(@product.id)
    end

    def product_permitted_params
      @_product_permitted_params ||= params.permit(policy(@product).product_permitted_attributes)
    end

    def check_banned
      e404 if @product.banned?
    end

    def ensure_seller_is_not_deleted
      e404_page if @product.user.deleted?
    end

    def ensure_domain_belongs_to_seller
      if @is_user_custom_domain
        e404_page unless @product.user == user_by_domain(request.host)
      end
    end

    def prepare_product_page
      @user                  = @product.user
      @title                 = @product.name
      @body_id               = "product_page"
      @is_on_product_page    = true
      @debug                 = params[:debug] && !Rails.env.production?
    end

    def link_params
      # These attributes are derived from a combination of attr_accessible on Link and other attributes as needed
      params.require(:link).permit(:name, :price_range, :rental_price_range, :price_currency_type, :price_cents, :rental_price_cents,
                                   :preview_url, :description, :unique_permalink, :native_type,
                                   :max_purchase_count, :require_shipping, :custom_receipt,
                                   :filetype, :filegroup, :size, :duration, :bitrate, :framerate,
                                   :pagelength, :width, :height, :custom_permalink,
                                   :suggested_price, :suggested_price_cents, :banned_at,
                                   :risk_score, :risk_score_updated_at, :customizable_price,
                                   :is_recurring_billing, :subscription_duration, :json_data,
                                   :is_physical, :skus_enabled, :block_access_after_membership_cancellation, :purchase_type,
                                   :should_include_last_post, :should_show_all_posts, :should_show_sales_count, :duration_in_months,
                                   :free_trial_enabled, :free_trial_duration_amount, :free_trial_duration_unit,
                                   :is_adult, :is_epublication, :product_refund_policy_enabled, :seller_refund_policy_enabled,
                                   :refund_policy, :taxonomy_id)
    end

    def paged_params
      params.permit(:page, sort: [:key, :direction])
    end

    def paginated_memberships(page:, query: nil)
      memberships = current_seller.products.membership.visible_and_not_archived
      memberships = memberships.where("name like ?", "%#{query}%") if query.present?

      sort_and_paginate_products(**paged_params[:sort].to_h.symbolize_keys, page:, collection: memberships, per_page: PER_PAGE, user_id: current_seller.id)
    end

    def paginated_products(page:, query: nil)
      products = current_seller
        .products
        .includes([
                    thumbnail: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } },
                    thumbnail_alive: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } },
                  ])
        .non_membership
        .visible_and_not_archived
      products = products.where("links.name like ?", "%#{query}%") if query.present?

      sort_and_paginate_products(**paged_params[:sort].to_h.symbolize_keys, page:, collection: products, per_page: PER_PAGE, user_id: current_seller.id)
    end

    def update_removed_file_attributes
      current = @product.file_info_for_product_page.keys.map(&:to_s)
      updated = (product_permitted_params[:file_attributes] || []).map { _1[:name] }
      @product.add_removed_file_info_attributes(current - updated)
    end

    def update_variants
      variant_category = @product.variant_categories_alive.first
      variants = product_permitted_params[:variants] || []
      if variants.any? || @product.is_tiered_membership?
        variant_category_params = variant_category.present? ?
          {
            id: variant_category.external_id,
            name: variant_category.title,
          } :
          { name: @product.is_tiered_membership? ? "Tier" : "Version" }
        Product::VariantsUpdaterService.new(
          product: @product,
          variants_params: [
            {
              **variant_category_params,
              options: variants,
            }
          ],
        ).perform
      elsif variant_category.present?
        Product::VariantsUpdaterService.new(
          product: @product,
          variants_params: [
            {
              id: variant_category.external_id,
              options: nil,
            }
          ]).perform
      end
    end

    def update_custom_domain
      if product_permitted_params[:custom_domain].present?
        custom_domain = @product.custom_domain || @product.build_custom_domain
        custom_domain.domain = product_permitted_params[:custom_domain]
        custom_domain.verify(allow_incrementing_failed_verification_attempts_count: false)
        custom_domain.save!
      elsif product_permitted_params[:custom_domain] == "" && @product.custom_domain.present?
        @product.custom_domain.mark_deleted!
      end
    end

    def update_availabilities
      return unless @product.native_type == Link::NATIVE_TYPE_CALL

      existing_availabilities = @product.call_availabilities
      availabilities_to_keep = []
      (product_permitted_params[:availabilities] || []).each do |availability_params|
        availability = existing_availabilities.find { _1.id == availability_params[:id] } || @product.call_availabilities.build
        availability.update!(availability_params.except(:id))
        availabilities_to_keep << availability
      end
      (existing_availabilities - availabilities_to_keep).each(&:destroy!)
    end

    def update_call_limitation_info
      return unless @product.native_type == Link::NATIVE_TYPE_CALL

      @product.call_limitation_info.update!(product_permitted_params[:call_limitation_info])
    end

    def update_installment_plan
      return unless @product.eligible_for_installment_plans?

      if @product.installment_plan && product_permitted_params[:installment_plan].present?
        @product.installment_plan.assign_attributes(product_permitted_params[:installment_plan])
        return unless @product.installment_plan.changed?
      end

      @product.installment_plan&.destroy_if_no_payment_options!
      @product.reset_installment_plan

      if product_permitted_params[:installment_plan].present?
        @product.create_installment_plan!(product_permitted_params[:installment_plan])
      end
    end

    def toggle_community_chat!(enabled)
      return unless Feature.active?(:communities, current_seller)
      return if [Link::NATIVE_TYPE_COFFEE, Link::NATIVE_TYPE_BUNDLE].include?(@product.native_type)

      @product.toggle_community_chat!(enabled)
    end

    def generate_product_details_using_ai
      if Rails.env.test?
        generate_product_cover_and_thumbnail_using_ai
        generate_product_content_using_ai
      else
        cover_thread = Thread.new { generate_product_cover_and_thumbnail_using_ai }
        content_thread = Thread.new { generate_product_content_using_ai }

        cover_thread.join
        content_thread.join
      end
    end

    def generate_product_cover_and_thumbnail_using_ai
      return unless @product.persisted?

      begin
        service = Ai::ProductDetailsGeneratorService.new(current_seller:)
        result = service.generate_cover_image(product_name: @product.name)
        image_data = result[:image_data]
        create_blob = ->(identifier) {
          ActiveStorage::Blob.create_and_upload!(
            io: StringIO.new(image_data),
            filename: "#{@product.external_id}_#{identifier}_#{Time.now.to_i}.jpeg",
            content_type: "image/jpeg",
            identify: false
          )
        }

        cover_image_blob = create_blob.call("cover")
        cover_image_blob.analyze
        asset_preview = @product.asset_previews.build
        asset_preview.file.attach(cover_image_blob)
        asset_preview.analyze_file
        asset_preview.save!

        thumbnail_image_blob = create_blob.call("thumbnail")
        thumbnail_image_blob.analyze
        thumbnail = @product.build_thumbnail
        thumbnail.file.attach(thumbnail_image_blob)
        thumbnail.file.analyze
        thumbnail.save!
      rescue => e
        Bugsnag.notify(e)
      end
    end

    def generate_product_content_using_ai
      return unless @product.persisted?

      number_of_content_pages = params[:link][:number_of_content_pages]
      if number_of_content_pages.present? && @product.native_type == Link::NATIVE_TYPE_EBOOK
        attribute = @product.custom_attributes.find { _1["name"] == "Pages" }
        attribute["value"] = number_of_content_pages.to_s if attribute.present?
        @product.save!
      end

      begin
        product_info = {
          name: @product.name,
          description: @product.description,
          native_type: @product.native_type,
          number_of_content_pages:
        }
        service = Ai::ProductDetailsGeneratorService.new(current_seller:)
        response = service.generate_rich_content_pages(product_info)

        response[:pages].each.with_index do |page_data, index|
          rich_content = @product.alive_rich_contents.build
          rich_content.title = page_data["title"]
          rich_content.description = page_data["content"] || []
          rich_content.position = index
          rich_content.save!
        end
      rescue => e
        Bugsnag.notify(e)
      end
    end
end
