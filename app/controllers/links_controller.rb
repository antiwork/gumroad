# frozen_string_literal: true

class LinksController < ApplicationController
  include ProductsHelper, SearchProducts, PreorderHelper, ActionView::Helpers::TextHelper,
          ActionView::Helpers::AssetUrlHelper, CustomDomainConfig, AffiliateCookie,
          CreateDiscoverSearch, DiscoverCuratedProducts, FetchProductByUniquePermalink

  include PageMeta::Favicon, PageMeta::Product
  include RequireAccountEmail
  include RendersCustomHtmlPages
  include MobileAppWebView

  enable_mobile_app_web_view only: %i[new create edit]

  # Products/Show and Products/Profile/Show both render from #show.
  self.buyer_currency_footer_actions = %w[show].freeze

  DEFAULT_PRICE = 500
  PRICE_INPUT_MAX_LENGTH = 64
  PRICE_INPUT_PATTERN = /\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)\z/

  prepend_before_action :disable_third_party_analytics!, only: :cart_items_count



  PUBLIC_ACTIONS = %i[show search increment_views track_user_action cart_items_count landing_iframe_content landing_version].freeze
  before_action :authenticate_user!, except: PUBLIC_ACTIONS
  after_action :verify_authorized, except: PUBLIC_ACTIONS
  skip_before_action :require_account_email, only: PUBLIC_ACTIONS + %i[publish]

  before_action :stick_to_primary_for_landing_iframe, only: %i[landing_iframe_content landing_version]
  before_action :fetch_product_for_show, only: %i[show landing_iframe_content landing_version]
  before_action :check_banned, only: %i[show landing_iframe_content landing_version]
  before_action :ensure_seller_is_not_deleted, only: %i[show landing_iframe_content landing_version]
  before_action :set_x_robots_tag_header, only: :show
  before_action :check_payment_details, only: :index

  before_action :set_affiliate_cookie, only: [:show]

  before_action :fetch_product, only: %i[increment_views track_user_action]
  before_action :check_if_needs_redirect, only: [:show]
  before_action :ensure_domain_belongs_to_seller, only: %i[show landing_iframe_content landing_version]
  before_action :render_custom_html_if_present, only: [:show]
  before_action :prepare_product_page, only: %i[show]
  before_action :fetch_product_and_enforce_ownership, only: %i[destroy]
  before_action :fetch_product_and_enforce_access, only: %i[update publish unpublish release_preorder update_sections]

  layout "inertia", only: %i[index new show cart_items_count edit]

  def index
    authorize Link

    set_meta_tag(title: "Products")

    render inertia: "Products/Index", props: products_page_presenter.page_props
  end

  def new
    authorize Link

    set_meta_tag(title: "What are you creating?")
    render inertia: "Products/New", props: ProductPresenter.new_page_props(current_seller:).merge(
      is_mobile_app_web_view: params[:display] == "mobile_app" || session[:mobile_app_web_view] == true
    )
  end

  def create
    authorize Link

    if params[:link][:is_physical]
      return head :forbidden unless current_seller.can_create_physical_products?
      params[:link][:quantity_enabled] = true
    end

    begin
      # Building the product and setting the price range both assign price_cents,
      # which raises Link::LinkInvalid when the price exceeds the maximum allowed.
      # Keep these inside the rescue below so an oversized price shows the user an
      # error message instead of a 500.
      @product = current_seller.links.build(link_params)
      @product.price_range = params[:link][:price_range]
    rescue Link::LinkInvalid => e
      return redirect_to new_product_path, alert: e.message, inertia: { errors: { "link.base" => e.message } }
    end

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

    # Only run AI generation for sellers who pass the same policy that gates the
    # dedicated generation endpoints (eligibility + team role). The prompt param is
    # client-supplied, so an ineligible seller could otherwise trigger AI service
    # work through ordinary product creation. When the policy fails we still create
    # the product normally — we just skip the AI step.
    ai_generated = params[:link][:ai_prompt].present? && policy(current_seller).generate_product_details_with_ai?

    begin
      @product.save!

      if ai_generated
        generate_product_details_using_ai
      end
    rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid
      # `errors.to_hash` maps attribute => [messages]; take the first attribute's
      # messages joined into a sentence. (Calling `.first` on the hash itself would
      # return a [key, value] pair, putting an Array into flash[:alert].)
      return redirect_to new_product_path, alert: @product.errors.to_hash.transform_values(&:to_sentence).values.first, inertia: inertia_errors(@product)
    end

    create_user_event("add_product")
    if ai_generated
      redirect_to edit_link_path(@product, ai_generated: true), status: :see_other
    else
      redirect_to edit_link_path(@product), status: :see_other
    end
  end

  def show
    return redirect_to custom_domain_coffee_path if @product.native_type == Link::NATIVE_TYPE_COFFEE
    ActiveRecord::Base.connection.stick_to_primary!
    # Force a preload of all association data used in rendering
    preload_product
    set_favicon_meta_tags(@product.user)

    if params[:wanted] == "true"
      params[:option] ||= params[:variant] && @product.options.find { |o| o[:name] == params[:variant] }&.[](:id)
      BasePrice::Recurrence::ALLOWED_RECURRENCES.each do |r|
        params[:recurrence] ||= r if params[r] == "true"
      end
      params[:price] = price_cents_from_units(params[:price]) if params[:price].present?
      cart_item = @product.cart_item(params)

      unless (@product.customizable_price || cart_item[:option]&.[](:is_pwyw)) &&
             (params[:price].blank? || params[:price] < cart_item[:price])
        discount_result = BestOfferCodeService.new(
          product: @product,
          url_code: params[:offer_code] || params[:code],
          quantity: (params[:quantity] || 1).to_i,
          buyer: logged_in_user
        ).result
        code = discount_result&.dig(:code) if discount_result&.dig(:valid)
        redirect_params = params.permit!.except(:code, :offer_code)
        return redirect_to checkout_url(**redirect_params, host: DOMAIN, product: @product.unique_permalink,
                                                           rent: cart_item[:rental], recurrence: cart_item[:recurrence],
                                                           price: cart_item[:price],
                                                           code: code,
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
    presenter_props = {
      recommended_by: params[:recommended_by],
      discount_code: params[:offer_code] || params[:code],
      quantity: (params[:quantity] || 1).to_i,
      layout: params[:layout],
      seller_custom_domain_url:,
      # Review reminder emails link logged-out bundle buyers here with their purchase's
      # external id and email digest, so the page can recognize the purchase and show
      # the review form without a signed-in session.
      purchase_id: params[:purchase_id],
      purchase_email_digest: params[:purchase_email_digest],
    }
    @body_class = "iframe" if params[:overlay] || params[:embed]

    if ["search", "discover"].include?(params[:recommended_by])
      # The clicked product's own category, not the browsed one: Discover click-throughs land here
      # without the taxonomy params the results page had, so this is the only side that can attribute
      # a click to a category at all.
      create_discover_search!(
        clicked_resource: @product,
        taxonomy_id: @product.taxonomy_id,
        query: params[:query],
        autocomplete: params[:autocomplete] == "true"
      )
    end

    set_noindex_header if !@product.alive?

    respond_to do |format|
      format.html do
        case params[:layout]
        when Product::Layout::PROFILE
          render inertia: "Products/Profile/Show", props: presenter.profile_product_props(**presenter_props)
        when Product::Layout::DISCOVER
          if request.headers["X-Inertia-Partial-Data"] == "autocomplete_results"
            return render inertia: "Products/Discover/Show", props: {
              autocomplete_results: Discover::AutocompletePresenter.new(
                query: params[:query],
                user: logged_in_user,
                browser_guid: cookies[:_gumroad_guid]
              ).props
            }
          end
          discover_props = { taxonomy_path: @product.taxonomy&.ancestry_path&.join("/"), taxonomies_for_nav: }
          render inertia: "Products/Discover/Show", props: presenter.discover_product_props(discover_props:, **presenter_props)
        else
          if params[:embed] || params[:overlay]
            render inertia: "Products/Iframe/Show", props: presenter.iframe_product_props(**presenter_props)
          elsif @product.user.product_page_storefront_enabled? && pundit_user&.seller != @product.user
            # Storefront-wrapped product page (gumroad-private#2196): profile header above the
            # product, catalog below (injected in ProductPresenter#product_page_props). Same
            # component the `layout=profile` branch above renders. The seller's own view keeps
            # the standalone page — the presenter suppresses the catalog for owners anyway.
            render inertia: "Products/Profile/Show", props: presenter.profile_product_props(**presenter_props)
          else
            render inertia: "Products/Show", props: presenter.product_page_props(**presenter_props)
          end
        end
      end
      format.json { render json: ProductPresenter::PublicApiProps.new(product: @product, seller_custom_domain_url:).props }
      format.any { e404 }
    end
  end

  def cart_items_count
    cart = Cart.fetch_by(user: logged_in_user, browser_guid: cookies[:_gumroad_guid])
    render inertia: "Products/CartItemsCount", props: {
      cart_items_count: cart&.cart_products&.alive&.count || 0
    }
  end

  def landing_iframe_content
    return head :not_found unless custom_html_visible?

    apply_custom_html_response_headers
    interpolated = Pages::Interpolator.interpolate(@product.custom_html, product: @product)
    render html: custom_html_document(interpolated).html_safe, layout: false
  end

  def landing_version
    return render_landing_version(visible: false, page: nil) unless can_preview_custom_html?
    page = @product&.page
    render_landing_version(visible: custom_html_visible? && page&.custom_html.present?, page:)
  end

  def search
    format_search_params!
    search_params = params
    in_section = search_params[:user_id].present?
    if in_section
      user = User.find_by_external_id(search_params[:user_id])
      section = user && user.seller_profile_products_sections.find_by_external_id(search_params[:section_id])
      # The profile page can show a virtual "default products section" (all of the creator's
      # live products) when the creator has products but hasn't saved any profile sections yet.
      # That section has no database row, so when the frontend fetches more results for it,
      # accept its well-known id and search across all the creator's profile products (leaving
      # `section` nil below does exactly that). Guarded on the creator having no saved product
      # sections — mirroring ProductPresenter's storefront catalog on product pages — so this id
      # can't be used to bypass a customized profile layout.
      searching_default_products_section =
        user.present? &&
        search_params[:section_id] == ProfileSectionsPresenter::DEFAULT_PRODUCTS_SECTION_ID &&
        user.seller_profile_products_sections.on_profile.none?
      return render json: { total: 0, filetypes_data: [], tags_data: [], taxonomy_attributes_data: [], products: [] } if user.nil? || (section.nil? && !searching_default_products_section && search_params[:ids].blank?)
      search_params[:section] = section if section
      search_params[:is_alive_on_profile] = true
      search_params[:user_id] = user.id
      search_params[:sort] = section&.default_product_sort if search_params[:sort].nil?
      search_params[:sort] = ProductSortKey::PAGE_LAYOUT if search_params[:sort] == "default" || search_params[:sort].nil?
      search_params[:ids]&.map! { ObfuscateIds.decrypt(_1) }
      if search_params[:exclude_ids].present?
        # Always overwrite (or drop) the key: leaving a crafted nested structure in place would
        # reach ES as a `terms` clause and 400 (→ public 500).
        exclude_ids = Array(search_params[:exclude_ids]).filter_map { _1.is_a?(String) ? ObfuscateIds.decrypt(_1) : nil }
        if exclude_ids.any?
          search_params[:exclude_ids] = exclude_ids
        else
          search_params.delete(:exclude_ids)
        end
      end
    else
      search_params[:sort] = ProductSortKey::FEATURED if search_params[:sort] == "default"
      search_params[:include_rated_as_adult] = logged_in_user&.show_nsfw_products?
      search_params[:curated_product_ids] = params[:curated_product_ids]&.map { ObfuscateIds.decrypt(_1) }
    end

    if search_params[:taxonomy].present?
      search_params[:taxonomy_id] = Taxonomy.find_by_path(params[:taxonomy].split("/"))&.id
      search_params[:include_taxonomy_descendants] = true
    end

    if in_section
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
        target: in_section ? Product::Layout::PROFILE : Product::Layout::DISCOVER,
        show_seller: !in_section,
        query: (search_params[:query] unless in_section),
        offer_code: (search_params[:offer_code] unless in_section)
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

    return redirect_to edit_bundle_product_path(@product.external_id) if @product.is_bundle?

    set_meta_tag(title: @product.name)

    ai_generated = params[:ai_generated] == "true"
    presenter = ProductPresenter.new(product: @product, pundit_user:, ai_generated:)
    render inertia: "Products/Edit", props: presenter.edit_props
  end

  def price_check
    fetch_product_by_unique_permalink
    authorize @product, :edit?
    return head :not_found unless Feature.active?(:price_checker, @product.user)

    begin
      result = PriceCheckerService.call(
        product: @product,
        overrides: sanitized_price_check_overrides,
        force_refresh: params[:refresh].present?,
      )
    rescue PriceCheckerService::TimeoutError
      return render json: { error: "timeout" }, status: :gateway_timeout
    end

    render json: result
  end

  def update
    authorize @product
    begin
      if custom_html_removal_update?
        @product.with_lock do
          @product.update!(custom_html: nil)
        end
        return render json: { success: true }
      end

      # This dashboard endpoint serves the editor's full-form save (which strips
      # custom_html) and the Remove button (custom_html-only, handled above). A
      # request mixing custom_html with other fields isn't a real client flow,
      # and it would fall through to the partial-update path below that clears any
      # collection the request omits (rich content, covers, shipping). Reject it;
      # the API v2 endpoint owns multi-field custom_html writes, guarding each
      # field independently.
      if custom_html_update?
        return render json: { error_message: "Use the API to publish custom_html; the dashboard only supports removing it." }, status: :unprocessable_entity
      end

      ActiveRecord::Base.transaction do
        # Serialize concurrent saves. lock! takes FOR UPDATE and reloads
        # (dropping stale association caches) so the freshness check below
        # reads committed state. Without it, two saves echoing the same
        # timestamps both pass and the last writer silently wins.
        @product.lock!

        # Capture the deletion-guard diagnostics (alive counts, persisted
        # shared-content flag) NOW, after the lock/reload but before
        # assign_attributes and the save steps below mutate the product — they
        # describe the committed pre-save state.
        deletion_guard_diagnostics

        # A save response has one global submitted-id => stored-id mapping for
        # content pages. The same submitted id cannot safely address two rows:
        # the editor would remap both references to one row and create another
        # duplicate on its next save. Old tabs can produce this while a page is
        # still present at its source and destination. Refuse it before any
        # cleanup, deletion, or product mutation and ask the seller to reload.
        ensure_rich_content_ids_are_unambiguous!

        # A later page move/copy needs provenance from the committed state,
        # even if this same transaction repairs or deletes its source first.
        legacy_dead_file_embed_ids_by_rich_content_id

        # Build the save contract now, before any write. Creating a content
        # page mutates the product fingerprint; only a post-lock, pre-write
        # contract answers "was the client editing the committed start state?"
        product_save_contract

        # Reject a DESTRUCTIVE save from a stale (or absent) snapshot before
        # any write. Silently skipping the deletion tells the seller "Changes
        # saved", clears pending removals, and leaves the versions in the DB.
        # Only destructive saves are refused — a stale typo-fix is recoverable;
        # a stale delete is not. Rejecting every stale save is what killed #6245.
        ensure_contract_deletions_are_fresh!

        # Reject a stale in-place overwrite before any mutation. Deletion
        # guards cannot catch this — an update under an existing id deletes
        # nothing. Seller-visible 409 is gated OFF by default
        # (`product_editor_stale_content_block`); without the flag this only
        # reports to Sentry. See Product::StaleContentWriteGuard.
        Product::StaleContentWriteGuard.ensure_fresh!(
          product: @product,
          pages_params: snapshot_pages_params,
          variants_params: snapshot_variants_params,
          diagnostics: deletion_guard_diagnostics
        )

        @product.assign_attributes(product_permitted_params.except(
          :products,
          :description,
          :cancellation_discount,
          :custom_button_text_option,
          :custom_summary,
          :custom_attributes,
          :taxonomy_attribute_values,
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
          :community_chat_enabled,
          :default_offer_code_id,
          :confirmed_removed_variant_ids,
          :confirmed_removed_rich_content_ids,
          :preserved_rich_content_ids,
          :rich_content_provenance_version
        ))
        @product.description = SaveContentUpsellsService.new(seller: @product.user, content: product_permitted_params[:description], old_content: @product.description_was).from_html
        @product.skus_enabled = false
        @product.save_custom_button_text_option(product_permitted_params[:custom_button_text_option]) unless product_permitted_params[:custom_button_text_option].nil?
        @product.save_custom_summary(product_permitted_params[:custom_summary]) unless product_permitted_params[:custom_summary].nil?
        @product.save_custom_attributes((product_permitted_params[:custom_attributes] || []).filter { _1[:name].present? || _1[:description].present? })
        # A taxonomy switch invalidates the prior taxonomy's attribute values even when the
        # request is category-only and omits taxonomy_attribute_values entirely (e.g. older
        # clients, the API). Re-run the save so values are normalized against the new taxonomy.
        # `taxonomy_id_changed?` alone would miss this: the save_custom_* calls above already
        # persisted the assigned taxonomy_id, so dirty tracking has cleared by the time we get
        # here — saved_change_to_taxonomy_id? reads the change from that just-committed save.
        if !product_permitted_params[:taxonomy_attribute_values].nil? || @product.taxonomy_id_changed? || @product.saved_change_to_taxonomy_id?
          @product.save_taxonomy_attribute_values(product_permitted_params[:taxonomy_attribute_values])
        end
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
          # Drop suggested amounts whose price was cleared (nil price_difference_cents):
          # an empty amount input reaches the backend as nil, coerces to 0, and would fail
          # the coffee variant's "greater than 0" validation. Ignore them entirely.
          coffee_variants = product_permitted_params[:variants]&.reject { _1[:price_difference_cents].nil? } || []
          product_permitted_params[:variants] = coffee_variants
          @product.suggested_price_cents = coffee_variants.filter_map { _1[:price_difference_cents] }.max
        end

        # TODO clean this up
        rich_content = product_permitted_params[:rich_content] || []
        rich_content_params = [*rich_content]
        product_permitted_params[:variants].each { rich_content_params.push(*_1[:rich_content]) } if product_permitted_params[:variants].present?
        rich_content_params = rich_content_params.flat_map { _1[:description] = _1.dig(:description, :content) }
        rich_contents_to_keep = []
        file_id_mappings = SaveFilesService.perform(@product, product_permitted_params, rich_content_params, contract: product_save_contract)
        save_id_mappings[:files].merge!(file_id_mappings) if file_id_mappings.present?
        existing_rich_contents = @product.alive_rich_contents.to_a
        rich_content.each.with_index do |product_rich_content, index|
          rich_content = existing_rich_contents.find { |c| c.external_id === product_rich_content[:id] } || @product.alive_rich_contents.build
          product_rich_content[:description] = SaveContentUpsellsService.new(seller: @product.user, content: product_rich_content[:description], old_content: rich_content.description || []).from_rich_content
          rich_content.assign_attributes(title: product_rich_content[:title].presence, description: product_rich_content[:description].presence || [], position: index)
          legacy_source_id = product_rich_content[:source_id].presence || product_rich_content[:id]
          removed_file_embed_ids = rich_content.remove_stale_dead_cross_product_file_embeds(
            legacy_dead_file_ids: legacy_dead_file_embed_ids_by_rich_content_id[legacy_source_id]
          )
          rich_content.save!
          rich_contents_to_keep << rich_content
          save_id_mappings[:removed_file_embeds][rich_content.external_id] = removed_file_embed_ids if removed_file_embed_ids.any?
          # A page submitted under an id the server didn't know was just
          # created with a canonical id — report the mapping so the editor's
          # next save addresses this page instead of re-creating it.
          if product_rich_content[:id].present? && product_rich_content[:id] != rich_content.external_id
            save_id_mappings[:rich_content][product_rich_content[:id]] = rich_content.external_id
            save_id_mappings[:rich_content_by_scope][""][product_rich_content[:id]] = rich_content.external_id
          end
        end
        product_rich_contents_to_delete = (existing_rich_contents - rich_contents_to_keep)
          .reject { preserved_rich_content_ids.include?(_1.external_id) }
        # Product::SaveContract, Rules 1 and 2. `existing - kept` is exactly the
        # omission-inference this contract exists to remove: a payload that
        # doesn't mention a page — including one strong parameters dropped
        # because it was malformed — currently reads as "delete that page".
        # Under the contract the diff stops being deletion authority: pages go
        # only when the client names them, or asks to clear the collection.
        product_rich_contents_to_delete = contract_scoped_rich_content_deletions(
          product_rich_contents_to_delete,
          existing_rich_contents
        )
        Product::RichContentDeletionGuard.ensure_intent!(
          product: @product,
          rich_contents_to_delete: product_rich_contents_to_delete,
          payload_page_ids:,
          confirmed_removed_ids: confirmed_removed_rich_content_ids,
          rewrite_budget: page_rewrite_budget,
          diagnostics: deletion_guard_diagnostics
        )
        product_rich_contents_to_delete.each(&:mark_deleted!)

        Product::SaveIntegrationsService.perform(@product, product_permitted_params[:integrations], contract: product_save_contract)
        update_variants
        update_removed_file_attributes
        update_custom_domain
        update_availabilities
        update_call_limitation_info
        update_installment_plan
        update_default_offer_code

        Product::SavePostPurchaseCustomFieldsService.new(@product).perform

        @product.is_licensed = @product.has_embedded_license_key?
        unless @product.is_licensed
          @product.is_multiseat_license = false
        end
        @product.description = SavePublicFilesService.new(resource: @product, files_params: product_permitted_params[:public_files], content: @product.description, contract: product_save_contract).process
        @product.save!
        toggle_community_chat!(product_permitted_params[:community_chat_enabled])
        @product.generate_product_files_archives!
      end
    rescue Product::StaleContentWriteGuard::StaleContentConflict => e
      # Raised before any mutation: the payload's echoed snapshot timestamps
      # are older than the stored rows, meaning another session saved after
      # this session loaded. Return the conflicting records so the editor can
      # show the seller what changed and offer a reload.
      log_editor_save_conflict("stale_content_conflict", stale_record_ids: e.stale_records.map { { type: _1[:type], id: _1[:id] } })
      return render json: {
        error_message: e.message,
        error_code: "stale_content_conflict",
        stale_records: e.stale_records,
      }, status: :conflict
    rescue Product::SaveContract::AmbiguousRichContentIdConflict => e
      # Raised under the product lock before any mutation. The current response
      # mapping has no scope dimension, so the client must reload rather than
      # guess which stored row a repeated submitted page id should address.
      log_editor_save_conflict("ambiguous_rich_content_id_conflict", @_rich_content_ambiguity_details || {})
      return render json: {
        error_message: e.message,
        error_code: "ambiguous_rich_content_id_conflict",
      }, status: :conflict
    rescue Product::SaveContract::StaleDeletionConflict => e
      # Raised before any mutation, so the rollback leaves removals pending.
      # The editor must NOT clear pending-removal state — the deletion has
      # not happened. Deliberately no fresh editor_revision: adopting one
      # would authorize the same stale snapshot on the next save, landing
      # the deletion and reverting a co-editor's intervening edits. The
      # client discards any token (saveProductError); a retry reloads.
      log_editor_save_conflict("stale_deletion_conflict")
      return render json: {
        error_message: e.message,
        error_code: "stale_deletion_conflict",
      }, status: :conflict
    rescue Product::RichContentDeletionGuard::HiddenVariantContentConflict => e
      # Fail-closed: hidden version-level pages AND real product-level content
      # both exist, so the save must not pick a winner. Return every hidden
      # version page (the guard raises on the first it inspects) for one
      # seller choice, not one dialog per version.
      log_editor_save_conflict("hidden_variant_content_conflict")
      return render json: {
        error_message: e.message,
        error_code: "hidden_variant_content_conflict",
        hidden_variant_pages: all_hidden_variant_pages,
      }, status: :unprocessable_entity
    rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid, Link::LinkInvalid => e
      if @product.errors.details[:custom_fields].present?
        error_message = "You must add titles to all of your inputs"
      else
        error_message = @product.errors.full_messages.first || e.message
      end
      return render json: { error_message: }, status: :unprocessable_entity
    rescue => e
      # Catch-all so an unanticipated failure never leaves the editor's save
      # request with no JSON body (gumroad-private#1784) — mirrors `publish`
      # above.
      ErrorNotifier.notify(e)
      return render json: { error_message: "Something went wrong while saving your changes. Please refresh the page and try again — if the problem continues, contact support." }, status: :unprocessable_entity
    end
    report_unapplied_deletions!
    report_unstated_confirmed_removals!

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
        warning_message: "The following offer #{"code".pluralize(all_invalid_offer_codes.count)} #{issue_description}: #{all_invalid_offer_codes.join(", ")}. Please update #{all_invalid_offer_codes.length > 1 ? "them or they" : "it or it"} will not work at checkout.",
        **save_id_mappings_response
      }
    end

    # The editor needs the canonical ids of records this save created (pages,
    # variants, and files submitted under client-generated ids) so its next save
    # addresses them instead of re-creating them — without this, saving twice
    # without a reload trips the content deletion guard or re-attaches files.
    render json: save_id_mappings_response
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
    rescue Errno::ENOENT => e
      ErrorNotifier.notify(e)
      return render json: { success: false, error_message: "There was a temporary issue processing your product images. Please try again." }
    rescue => e
      ErrorNotifier.notify(e)
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

    new_price = price_cents_from_units(params.require(:amount))
    return render json: { success: false, error: "Invalid amount" }, status: :unprocessable_entity if new_price.nil?

    CustomerLowPriorityMailer.sample_subscription_price_change_notification(
      user: logged_in_user,
      tier:,
      effective_date: params[:effective_date].present? ? Date.parse(params[:effective_date]) : tier.subscription_price_change_effective_date,
      recurrence: params.require(:recurrence),
      new_price:,
      custom_message: strip_tags(params[:custom_message]).present? ? params[:custom_message] : nil,
    ).deliver_later

    render json: { success: true }
  end

  private
    def price_cents_from_units(value)
      value = value.to_s
      return if value.length > PRICE_INPUT_MAX_LENGTH || !value.match?(PRICE_INPUT_PATTERN)

      decimal_value = BigDecimal(value)
      return if decimal_value.negative?

      scaling_factor = @product.single_unit_currency? ? 1 : 100
      price_cents = (decimal_value * scaling_factor).round
      price_cents if price_cents.in?(0..BasePrice::Shared::MAX_PRICE_CENTS)
    end

    NAME_OVERRIDE_MAX = 250
    DESCRIPTION_OVERRIDE_MAX = 5_000

    def sanitized_price_check_overrides
      raw = params.permit(overrides: [:name, :description, :taxonomy_id, :native_type, :currency_code])[:overrides]
      return {} unless raw.is_a?(ActionController::Parameters) || raw.is_a?(Hash)
      overrides = {}

      if raw.key?(:name) || raw.key?("name")
        candidate = raw[:name].to_s.strip
        overrides[:name] = candidate if candidate.length <= NAME_OVERRIDE_MAX
      end
      if raw.key?(:description) || raw.key?("description")
        candidate = raw[:description].to_s
        overrides[:description] = candidate if candidate.length <= DESCRIPTION_OVERRIDE_MAX
      end
      if raw.key?(:taxonomy_id) || raw.key?("taxonomy_id")
        candidate = raw[:taxonomy_id]
        if candidate.nil? || candidate.to_s.empty?
          overrides[:taxonomy_id] = nil
        else
          taxonomy_id = candidate.to_i
          overrides[:taxonomy_id] = taxonomy_id if taxonomy_id > 0 && Taxonomy.exists?(id: taxonomy_id)
        end
      end
      if raw.key?(:native_type) || raw.key?("native_type")
        candidate = raw[:native_type].to_s
        overrides[:native_type] = candidate if Link::NATIVE_TYPES.include?(candidate)
      end
      if raw.key?(:currency_code) || raw.key?("currency_code")
        candidate = raw[:currency_code].to_s.downcase
        overrides[:currency_code] = candidate if CURRENCY_CHOICES.key?(candidate)
      end
      overrides
    end

    def fetch_product_for_show
      fetch_product_by_custom_domain || fetch_product_by_general_permalink
    end

    def fetch_product_by_custom_domain
      @product = product_by_custom_domain
    end

    def product_by_custom_domain
      @_product_by_custom_domain ||= begin
        product = CustomDomain.find_by_host(request.host)&.product
        general_permalink = product&.general_permalink
        if general_permalink.blank?
          nil
        else
          Link.fetch_leniently(general_permalink, user: product.user)
        end
      end
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
      @_product_permitted_params ||= begin
        permitted = params.permit(policy(@product).product_permitted_attributes)
        permitted.delete(:custom_html) unless Feature.active?(:custom_html_pages, @product.user)
        permitted
      end
    end

    # Built from PERMITTED params so submitted? sees collections as strong
    # parameters shaped them — a dropped malformed value is "not submitted".
    # editor_revision / deletion_operations are not product attributes, so
    # they are permitted here rather than in the policy.
    # deep_symbolize_keys is load-bearing: the contract digs symbol keys, and
    # Parameters#to_unsafe_h.symbolize_keys re-stringifies NESTED keys.
    def product_save_contract
      @_product_save_contract ||= begin
        contract_params = product_permitted_params.to_h.deep_symbolize_keys.merge(
          params.permit(
            :editor_revision,
            deletion_operations: {
              deleted_ids: {
                files: [],
                public_files: [],
                integrations: [],
                variants: [],
                rich_content: [],
              },
              cleared_collections: [],
            }
          ).to_h.deep_symbolize_keys
        ).deep_merge(variant_scoped_deletion_params)

        # Tabs opened before provenance support represented a cross-scope move
        # by reusing the stored page id at its destination, without naming the
        # source deletion. The submitted id and changed owner scope prove that
        # move from the locked pre-save state. Add only that source row to the
        # deletion request; with the save contract enforced, a missing or stale
        # revision then fails before mutation instead of leaving two copies.
        inferred_move_ids = legacy_inferred_moved_rich_content_external_ids
        if inferred_move_ids.any?
          contract_params[:deletion_operations] ||= {}
          contract_params[:deletion_operations][:deleted_ids] ||= {}
          requested_ids = Array(contract_params.dig(:deletion_operations, :deleted_ids, :rich_content))
          contract_params[:deletion_operations][:deleted_ids][:rich_content] = (requested_ids | inferred_move_ids)
        end

        Product::SaveContract.new(params: contract_params, product: @product)
      end
    end

    # Version-scoped deletion operations, permitted separately because their
    # keys are variant external ids — arbitrary strings that cannot be named in
    # a static `permit` list.
    #
    # Each variant id maps to a per-collection list, so the shape is validated
    # by hand rather than trusted: anything that is not a hash of
    # collection => array-of-strings is dropped, which lands a malformed
    # payload on "no deletions requested" instead of raising inside the save.
    def variant_scoped_deletion_params
      raw = params[:deletion_operations]
      # `raw` is client-controlled and may be any shape. A bare String responds
      # to `[]` but raises TypeError on a Symbol key, so `respond_to?(:[])` is
      # not a sufficient guard here — require the hash-like shape explicitly.
      return {} unless raw.is_a?(Hash) || raw.is_a?(ActionController::Parameters)

      by_owner = raw[:variant_deleted_ids]
      return {} unless by_owner.respond_to?(:each_pair)

      scoped = by_owner.each_pair.with_object({}) do |(owner_id, collections), acc|
        next unless collections.respond_to?(:each_pair)

        permitted = collections.each_pair.with_object({}) do |(collection, ids), inner|
          next unless collection.to_sym.in?(Product::SaveContract::COLLECTIONS)
          next unless ids.is_a?(Array)

          inner[collection.to_sym] = ids.select { _1.is_a?(String) || _1.is_a?(Symbol) }.map(&:to_s)
        end
        acc[owner_id.to_s] = permitted if permitted.any?
      end

      scoped.any? ? { deletion_operations: { variant_deleted_ids: scoped } } : {}
    end

    # Narrows a diff-derived set of pages down to what the contract actually
    # authorises removing. Returns the input untouched when the contract is not
    # enforced, so the flag-off path is byte-identical to before.
    #
    # `cleared?` deletes from the PRE-SAVE set rather than the diff, so a
    # clear-all means "everything that existed when the editor loaded" and can
    # never sweep up a page created by this same request.
    def contract_scoped_rich_content_deletions(diff_deletions, existing_rich_contents)
      contract = product_save_contract
      return diff_deletions unless contract.enforced?

      if contract.cleared?(:rich_content)
        return existing_rich_contents.reject { preserved_rich_content_ids.include?(_1.external_id) }
      end

      ids = contract.deleted_ids(:rich_content)
      return [] if ids.empty?

      existing_rich_contents.select { ids.include?(_1.external_id) }
        .reject { preserved_rich_content_ids.include?(_1.external_id) }
    end

    # Refuses a destructive save whose snapshot token is missing or stale.
    #
    # Raised (rather than returned) so it unwinds inside the transaction that
    # wraps the save: nothing has been written at this point, the rollback
    # releases the product lock, and the rescue renders a 409 the editor can act
    # on. A write-only save is never refused here.
    def ensure_contract_deletions_are_fresh!
      contract = product_save_contract
      return unless contract.enforced?
      return unless contract.requested_deletion?
      return if contract.may_delete?

      raise Product::SaveContract::StaleDeletionConflict
    end

    def ensure_rich_content_ids_are_unambiguous!
      references = submitted_rich_content_page_references
      # Older editor tabs only understand the global response map, so keep
      # enforcing global uniqueness until the scoped-mapping protocol is sent.
      if product_permitted_params[:rich_content_provenance_version].to_i < 2
        duplicate_ids = references.filter_map { _1[:page][:id].presence }.tally.select { |_id, count| count > 1 }.keys
        raise_ambiguous_rich_content_conflict!(check: "global", conflicts: duplicate_ids) if duplicate_ids.any?
        return
      end

      per_scope_duplicate_ids = references
        .group_by { _1[:destination_scope_key] }
        .transform_values { |refs| refs.filter_map { _1[:page][:id].presence }.tally.select { |_id, count| count > 1 }.keys }
        .select { |_scope, ids| ids.any? }
      raise_ambiguous_rich_content_conflict!(check: "per_scope", conflicts: per_scope_duplicate_ids) if per_scope_duplicate_ids.any?

      # Only new client ids may repeat across scopes. A persisted page belongs
      # to one scope, so addressing it from multiple destinations is ambiguous.
      existing_id_scopes = references
        .filter_map do |ref|
          raw_id = ref[:page][:id].presence
          next unless raw_id && owned_submitted_rich_content_pages_by_external_id[raw_id]

          [raw_id, ref[:destination_scope_key]]
        end
        .group_by(&:first)
        .transform_values { |pairs| pairs.map(&:last).uniq }
        .select { |_id, scopes| scopes.size > 1 }
      raise_ambiguous_rich_content_conflict!(check: "existing_id_multiple_scopes", conflicts: existing_id_scopes) if existing_id_scopes.any?
    end

    # Captures which check fired and the offending ids/scopes for the rescue
    # in #update to log. Ids and scope keys are opaque identifiers, never
    # seller content.
    def raise_ambiguous_rich_content_conflict!(check:, conflicts:)
      @_rich_content_ambiguity_details = { check:, conflicts: }
      raise Product::SaveContract::AmbiguousRichContentIdConflict
    end

    # One greppable line per refused editor save. Lograge strips params, so
    # without this the conflict responses are indistinguishable in production
    # logs (gumroad-private#2023).
    def log_editor_save_conflict(error_code, details = {})
      detail_suffix = details.map { |key, value| " #{key}=#{value.inspect}" }.join
      Rails.logger.info(
        "[product_editor_save_conflict] error_code=#{error_code} product_id=#{@product.id} " \
        "seller_id=#{@product.user_id} provenance_version=#{product_permitted_params[:rich_content_provenance_version].to_i} " \
        "request_id=#{request.request_id}#{detail_suffix}"
      )
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

    def custom_html_visible?
      @product.present? && Feature.active?(:custom_html_pages, @product.user) && @product.custom_html.present? && (@product.alive? || can_preview_custom_html?)
    end

    def can_preview_custom_html?
      logged_in_user.present? && (logged_in_user == @product.user || logged_in_user.collaborator_for?(@product) || logged_in_user.is_team_member?)
    end

    def custom_html_removal_update?
      product_permitted_params.keys == ["custom_html"] && product_permitted_params[:custom_html].blank?
    end

    def custom_html_update?
      product_permitted_params.key?("custom_html")
    end

    def prepare_product_page
      @user                  = @product.user
      set_meta_tag(title: @product.name)
      set_product_page_meta(@product)
      set_meta_tag(tag_name: "style", inner_content: @product.user.seller_profile.custom_styles.to_s, head_key: "custom_styles")
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

    def products_page_presenter
      @products_page_presenter ||= DashboardProductsPagePresenter.new(
        pundit_user:,
        query: index_params[:query],
        products_page: index_params[:products_page],
        products_sort: index_params[:products_sort],
        memberships_page: index_params[:memberships_page],
        memberships_sort: index_params[:memberships_sort]
      )
    end

    def index_params
      @index_params ||= begin
        permitted = params.permit(
          :query, :products_page, :memberships_page,
          :products_sort_key, :products_sort_direction,
          :memberships_sort_key, :memberships_sort_direction
        )

        {
          query: permitted[:query],
          products_page: permitted[:products_page],
          products_sort: extract_sort_params(:products, permitted),
          memberships_page: permitted[:memberships_page],
          memberships_sort: extract_sort_params(:memberships, permitted)
        }
      end
    end

    def extract_sort_params(prefix, permitted)
      key = permitted[:"#{prefix}_sort_key"]
      direction = permitted[:"#{prefix}_sort_direction"]
      return nil unless %w[name display_price_cents successful_sales_count revenue status].include?(key)
      { key:, direction: direction == "desc" ? "desc" : "asc" }
    end

    def update_removed_file_attributes
      current = @product.file_info_for_product_page.keys.map(&:to_s)
      updated = (product_permitted_params[:file_attributes] || []).map { _1[:name] }
      @product.add_removed_file_info_attributes(current - updated)
    end

    def update_variants
      alive_categories = @product.variant_categories_alive.to_a
      variant_category = alive_categories.first
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
            },
            *deletion_only_category_params(alive_categories, except: variant_category),
          ],
          confirmed_removed_variant_ids:,
          payload_page_ids:,
          confirmed_removed_rich_content_ids:,
          preserved_rich_content_ids:,
          rewrite_budget: page_rewrite_budget,
          deletion_guard_diagnostics:,
          id_mappings: save_id_mappings,
          legacy_dead_file_embed_ids_by_rich_content_id:,
          deletion_audit_context:,
          contract: product_save_contract,
        ).perform
      elsif variant_category.present?
        Product::VariantsUpdaterService.new(
          product: @product,
          variants_params: [
            {
              id: variant_category.external_id,
              options: nil,
            },
            *deletion_only_category_params(alive_categories, except: variant_category),
          ],
          confirmed_removed_variant_ids:,
          payload_page_ids:,
          confirmed_removed_rich_content_ids:,
          preserved_rich_content_ids:,
          rewrite_budget: page_rewrite_budget,
          deletion_guard_diagnostics:,
          id_mappings: save_id_mappings,
          legacy_dead_file_embed_ids_by_rich_content_id:,
          deletion_audit_context:,
          contract: product_save_contract,
        ).perform
      end
    end

    # The editor only ever addresses the product's FIRST alive variant grouping
    # — that is what the UI shows and what the payload's `variants` list means.
    # Everything else the product owns (a second grouping left over from the
    # older multi-category editor, or from the API) is simply not part of the
    # request, so the save never visits it.
    #
    # That is fine while deletion is inferred from the payload, because a
    # grouping nobody submitted has nothing to infer from. Under the save
    # contract it stops being fine: the client can now name a specific variant
    # id to delete, and if that variant lives in a grouping the save never
    # visits, the deletion is silently dropped — the save returns success and
    # the version is still there after a reload.
    #
    # So when (and only when) the contract is enforced and the request names ids
    # or asks for a clear-all, the other alive groupings are appended as
    # deletion-only entries (`options: nil`). Under the contract that route
    # deletes exactly the named ids and nothing else
    # (VariantCategoryUpdaterService#contract_scoped_category_deletions), so a
    # grouping with no named ids is visited and left completely alone.
    #
    # Version-scoped deletions (a version's integrations) count as "names ids"
    # for exactly the same reason: they name a version by its external id, and
    # that version can live in any grouping. Without them in this condition a
    # fresh, explicitly authorised request to disconnect an integration from a
    # version outside the first grouping would return 200 with the integration
    # still connected.
    #
    # Returns [] whenever the contract is off, which keeps the legacy single-
    # grouping call byte-identical.
    def deletion_only_category_params(alive_categories, except:)
      contract = product_save_contract
      return [] unless contract.enforced?

      names_deletions = contract.cleared?(:variants) ||
        contract.deleted_ids(:variants).any? ||
        contract.variant_deletion_owner_ids.any?
      return [] unless names_deletions

      alive_categories
        .reject { _1.id == except&.id }
        .map { { id: _1.external_id, options: nil } }
    end

    # Who and which request is performing this save, for the deletion audit
    # trail (ProductVariantDeletionAudit). `logged_in_user` rather than
    # `current_seller`: on a collaborator or admin save those differ, and the
    # audit wants the person who actually pressed save.
    #
    # `correlation_id` is a server-side digest, not the raw request id — Rails
    # takes `X-Request-Id` from the client, so the raw value is caller-controlled
    # (see AuditCorrelationId). `revision_token` is always nil today: the
    # editor-scoped revision token proposed in gumroad-private#1379 does not
    # exist yet, and the key is here so the audit shape doesn't change when it
    # ships.
    #
    # The digest is computed here but NOT logged here: this context is built for
    # every save, and most saves delete nothing. Logging at build time would emit
    # a correlation line for saves that never produce an audit row, which is noise
    # that makes the log useless for the one thing it exists for — finding the
    # request behind an audit row. `ProductVariantDeletionAudit` logs the pair
    # itself, at the point a row is actually scheduled.
    def deletion_audit_context
      @_deletion_audit_context ||= {
        actor_user_id: logged_in_user&.id,
        correlation_id: AuditCorrelationId.for(request.request_id),
        request_id: request.request_id,
        # The snapshot token the client submitted, recorded so an audit row can
        # be tied back to the editor session that asked for the deletion.
        # Read straight from the params rather than from the contract: the audit
        # must describe what the client actually sent even when the contract is
        # disabled, and reading it here cannot start any revision work.
        revision_token: params[:editor_revision].presence,
      }
    end

    # External ids of variants the seller explicitly removed in the editor (via
    # the "Remove version/tier/duration" confirmation modal). Used to distinguish
    # an intentional deletion from an outdated or blind payload that simply
    # doesn't know about a variant.
    def confirmed_removed_variant_ids
      Array.wrap(product_permitted_params[:confirmed_removed_variant_ids])
    end

    # External ids of content pages the seller explicitly deleted or replaced in
    # the editor (delete-page modal, copy-content-from-version, discard-other-
    # versions'-content).
    def confirmed_removed_rich_content_ids
      Array.wrap(product_permitted_params[:confirmed_removed_rich_content_ids])
    end

    # External ids of version-level pages the seller chose to KEEP in the
    # hidden-content conflict dialog ("Keep version content"). Those pages are
    # hidden from the editor by the shared-content flag, so they can never
    # appear in the save payload — this list tells the server their absence is
    # deliberate preservation, not deletion.
    def preserved_rich_content_ids
      Array.wrap(product_permitted_params[:preserved_rich_content_ids])
    end

    # Every page id present anywhere in the save payload (product-level and
    # variant-level). A page whose id appears here isn't being deleted — at most
    # it's moving between the product level and a variant (e.g. toggling "use the
    # same content for all versions"), so the deletion guards must not block it.
    def payload_page_ids
      @_payload_page_ids ||= begin
        product_pages = product_permitted_params[:rich_content]
        ids = product_pages.is_a?(Array) ? product_pages.map { _1[:id] } : []
        (product_permitted_params[:variants] || []).each do |variant|
          variant_pages = variant[:rich_content]
          ids.concat(variant_pages.map { _1[:id] }) if variant_pages.is_a?(Array)
        end
        ids.compact
      end
    end

    # Descriptions of payload pages the server does NOT already know about.
    # Editor sessions predating the id reconciliation in the save response keep
    # their client-generated page ids across saves, so a resubmitted new page
    # arrives under an unknown id: matching on content identifies it as a
    # rewrite rather than a deletion. Pages submitted under an id the server
    # already has are in-place updates of that page — their content must NOT
    # unlock deleting a different stored page that happens to have the same
    # content (two duplicate-content pages, an outdated payload omits one).
    # NOTE: reads the RAW params, not the permitted ones — by the time the
    # deletion guards run, the permitted variant params may have been
    # consumed/mutated by earlier steps.
    def payload_page_descriptions
      @_payload_page_descriptions ||= begin
        pages = params[:rich_content].is_a?(Array) ? params[:rich_content].to_a : []
        (params[:variants].is_a?(Array) ? params[:variants] : []).each do |variant|
          pages.concat(variant[:rich_content].to_a) if variant[:rich_content].is_a?(Array)
        end
        known_page_ids = (@product.alive_rich_contents.map(&:external_id) +
          @product.current_base_variants.flat_map { |variant| variant.alive_rich_contents.map(&:external_id) }).to_set
        pages.filter_map do |page|
          next if page[:id].present? && known_page_ids.include?(page[:id])
          page[:description].present? ? page[:description][:content].as_json : nil
        end
      end
    end

    # The request-wide rewrite allowance shared by every deletion-guard
    # invocation in this save (product-level pages + each variant's pages).
    # Memoized so all invocations consume from the SAME budget — otherwise a
    # single resubmitted page could authorize one deletion per scope instead
    # of one deletion total.
    def page_rewrite_budget
      @_page_rewrite_budget ||= Product::RichContentDeletionGuard.build_rewrite_budget(payload_page_descriptions)
    end

    # Every page in the save payload (product-level and variant-level) with the
    # snapshot timestamp the editor echoed for it, for the stale-write guard
    # (Product::StaleContentWriteGuard). Reads the RAW params like
    # payload_page_descriptions does, and runs before the save mutates anything.
    def snapshot_pages_params
      pages = params[:rich_content].is_a?(Array) ? params[:rich_content].to_a : []
      (params[:variants].is_a?(Array) ? params[:variants] : []).each do |variant|
        pages.concat(variant[:rich_content].to_a) if variant[:rich_content].is_a?(Array)
      end
      pages.filter_map { |page| { id: page[:id], updated_at: page[:updated_at] } if page.is_a?(ActionController::Parameters) || page.is_a?(Hash) }
    end

    # Every variant in the save payload with the snapshot timestamp the editor
    # echoed for it, for the stale-write guard. The whole variant hash is
    # passed through (not just id/updated_at) because the guard compares the
    # submitted attributes against the stored row: a variant row's updated_at
    # is also bumped by ordinary sales, so a newer timestamp alone doesn't mean
    # another editor session saved.
    def snapshot_variants_params
      variants = params[:variants].is_a?(Array) ? params[:variants] : []
      variants.select { |variant| variant.is_a?(ActionController::Parameters) || variant.is_a?(Hash) }
    end

    # Non-PII diagnostics attached to every blocked-save notification so an
    # incident like the July 21, 2026 wipe is diagnosable from the alert alone
    # (the request body isn't retained). Must be built BEFORE the save mutates
    # the product — the alive counts and the persisted shared-content flag
    # describe the pre-save state; `update` calls this before
    # assign_attributes and the value is memoized.
    def deletion_guard_diagnostics
      @_deletion_guard_diagnostics ||= {
        submitted_variant_count: params[:variants].is_a?(Array) ? params[:variants].size : 0,
        alive_variant_count: @product.alive_variants.count,
        submitted_page_count: submitted_page_count,
        alive_page_count: @product.alive_rich_contents.count + @product.current_base_variants.sum { |variant| variant.alive_rich_contents.count },
        persisted_has_same_rich_content_for_all_variants: @product.has_same_rich_content_for_all_variants?,
        # Whether the product level had visible content BEFORE this save
        # touched anything. The hidden-content guard classifies conflicts from
        # this (not from the live rows, which the transaction has already
        # mutated by the time the per-variant guards run).
        persisted_product_level_has_editor_content: @product.alive_rich_contents.any?(&:has_editor_content?),
        submitted_has_same_rich_content_for_all_variants: params.key?(:has_same_rich_content_for_all_variants) ? ActiveModel::Type::Boolean.new.cast(params[:has_same_rich_content_for_all_variants]) : nil,
      }
    end

    def submitted_page_count
      count = params[:rich_content].is_a?(Array) ? params[:rich_content].size : 0
      count + (params[:variants].is_a?(Array) ? params[:variants].sum { |variant| variant[:rich_content].is_a?(Array) ? variant[:rich_content].size : 0 } : 0)
    end

    # A save that named deletions and applied fewer of them than it named is a
    # success response the seller cannot tell apart from a real one
    # (gumroad-private#1508). Under the save contract an unstated removal is a
    # no-op by design, so the failure mode that used to be a wrong deletion is
    # now a silent non-deletion: 200, nothing gone, nothing logged.
    #
    # Runs only on the success path, after the transaction committed, and only
    # when the client actually stated deletions — so it costs one reload plus
    # two id reads on the small minority of saves that delete something, and
    # nothing at all on the rest.
    #
    # Never raises. This is a report, not a guard: the write already happened
    # and failing the response here would tell the seller a committed save
    # failed.
    def report_unapplied_deletions!
      contract = product_save_contract
      return unless contract.enforced?
      return unless contract.requested_deletion?

      requested_variants = contract.deleted_ids(:variants)
      requested_pages = contract.deleted_ids(:rich_content)
      return if requested_variants.empty? && requested_pages.empty?

      @product.reload
      surviving_variants = surviving_variant_ids(requested_variants)
      surviving_pages = surviving_rich_content_ids(requested_pages)
      return if surviving_variants.empty? && surviving_pages.empty?

      ErrorNotifier.notify(
        "Product save applied fewer deletions than it named",
        product_id: @product.id,
        seller_id: @product.user_id,
        request_id: request.request_id,
        requested_variant_ids: requested_variants,
        surviving_variant_ids: surviving_variants,
        requested_rich_content_ids: requested_pages,
        surviving_rich_content_ids: surviving_pages,
      )
    rescue StandardError => e
      ErrorNotifier.notify(e)
    end

    # The blind spot in the report above: it is gated on `requested_deletion?`,
    # so it cannot see a payload that named NO deletion at all. That is exactly
    # the shape reported in gumroad-private#1508 — 200, nothing deleted, zero
    # audit rows — and it is why the report has never fired.
    #
    # `confirmed_removed_variant_ids` is the witness. The editor sends it beside
    # the deletion operations and both derive from the same in-session list, so a
    # contract-aware payload that confirms a removal while naming none of it is
    # self-contradictory: the seller pressed "Yes, remove" and the request did
    # not ask for it. Under Rule 1 the server correctly does nothing, which is
    # what makes the failure silent.
    #
    # A current client cannot produce that contradiction — both lists come off
    # one snapshot. This is a tripwire for the clients that can: a stale bundle,
    # or a path nobody has found yet. It does NOT catch a row dropped from state
    # with no confirmed id, which is undetectable here by contract design.
    #
    # Report, not guard: acting on the confirmed ids would delete rows through a
    # route the contract deliberately closed.
    def report_unstated_confirmed_removals!
      contract = product_save_contract
      return unless contract.enforced?
      # A tab that predates the contract cannot state deletions, so its
      # confirmed ids are not a contradiction.
      return unless contract.contract_aware?

      unstated_variants = unstated_confirmed_ids(:variants, confirmed_removed_variant_ids)
      unstated_pages = unstated_confirmed_ids(:rich_content, confirmed_removed_rich_content_ids)
      return if unstated_variants.empty? && unstated_pages.empty?

      @product.reload
      # Still-alive is what makes this a live defect rather than a replayed
      # payload: the editor clears its confirmed ids after a successful save,
      # so a resend naming already-deleted rows is noise.
      surviving_variants = surviving_variant_ids(unstated_variants)
      surviving_pages = surviving_rich_content_ids(unstated_pages)
      return if surviving_variants.empty? && surviving_pages.empty?

      ErrorNotifier.notify(
        "Product save confirmed a removal its deletion operations never named",
        product_id: @product.id,
        seller_id: @product.user_id,
        request_id: request.request_id,
        confirmed_variant_ids: confirmed_removed_variant_ids,
        unstated_variant_ids: surviving_variants,
        confirmed_rich_content_ids: confirmed_removed_rich_content_ids,
        unstated_rich_content_ids: surviving_pages,
        named_variant_ids: contract.raw_deleted_ids(:variants),
        named_rich_content_ids: contract.raw_deleted_ids(:rich_content),
      )
    rescue StandardError => e
      ErrorNotifier.notify(e)
    end

    # Confirmed ids the payload did not carry into a deletion operation. A
    # clear-all states every id in the collection, so it contradicts nothing.
    def unstated_confirmed_ids(collection, confirmed_ids)
      confirmed = Array(confirmed_ids).map(&:to_s).uniq.reject(&:blank?)
      return [] if confirmed.empty?

      contract = product_save_contract
      return [] if contract.raw_cleared?(collection)

      confirmed - contract.raw_deleted_ids(collection)
    end

    # Survivors are looked up by the requested id rather than by walking the
    # product's live parents. A version that survived under a grouping this
    # save deleted (the API's category destroy leaves live children; older
    # editor saves did too, gumroad-private#1784) is unreachable through
    # `current_base_variants` — exactly the rows this report exists to name.
    def surviving_variant_ids(requested_ids)
      return [] if requested_ids.empty?

      BaseVariant.alive.by_external_ids(requested_ids)
        .select { variant_belongs_to_product?(_1) }
        .map(&:external_id)
    end

    # A page under a version this save DID delete is not a survivor: version
    # deletion hands its pages to DeleteProductRichContentWorker, so the row is
    # still alive at commit by design and reporting it would fire on every
    # successful version removal.
    def surviving_rich_content_ids(requested_ids)
      return [] if requested_ids.empty?

      RichContent.alive.by_external_ids(requested_ids)
        .select { rich_content_survived?(_1) }
        .map(&:external_id)
    end

    # A version reaches the product either directly (SKUs) or through its
    # grouping, and the grouping may itself be soft-deleted by this save —
    # `belongs_to` is unscoped, so the link is still readable.
    def variant_belongs_to_product?(variant)
      return true if variant.link_id == @product.id

      variant.try(:variant_category)&.link_id == @product.id
    end

    def rich_content_survived?(page)
      entity = page.entity
      return entity.id == @product.id if entity.is_a?(Link)
      return variant_belongs_to_product?(entity) && entity.alive? if entity.is_a?(BaseVariant)

      false
    end

    # Accumulates client id → canonical server id for records this save
    # creates (pages, variants, and files submitted under client-generated ids).
    # Returned to the editor so its next save addresses the created records
    # instead of re-creating them (which would trip the deletion guards).
    def save_id_mappings
      @_save_id_mappings ||= {
        variants: {},
        rich_content: {},
        rich_content_by_scope: Hash.new { |scopes, scope| scopes[scope] = {} },
        files: {},
        removed_file_embeds: {},
      }
    end

    # Snapshot stored move/copy provenance before this save can repair or
    # delete a source page. Current clients name the source explicitly. For a
    # marker-less request from a tab opened before provenance support, a reused
    # stored id proves a move; a new id can prove a copy only by intersecting
    # its submitted dead embeds with dead embeds already stored in this
    # product. That compatibility scan never admits an alive foreign file or a
    # dead id absent from this product's stored content.
    #
    # The current protocol queries only named sources. The bounded legacy copy
    # fallback loads the product's pages in batches, not once per version or
    # page. Every ownership check comes from the locked pre-save state, so a
    # client cannot cite another product's page as cleanup authority.
    def legacy_dead_file_embed_ids_by_rich_content_id
      @_legacy_dead_file_embed_ids_by_rich_content_id ||= begin
        source_external_ids = submitted_legacy_rich_content_source_external_ids
        source_pages_by_external_id = owned_submitted_rich_content_pages_by_external_id.slice(*source_external_ids)
        legacy_destinations = legacy_unknown_rich_content_destinations
        provenance_pages = source_pages_by_external_id.values
        if legacy_destinations.any?
          provenance_pages |= all_owned_alive_rich_content_pages
        end

        embedded_file_ids_by_page = provenance_pages.to_h do |page|
          [page.external_id, page.embedded_product_file_ids_in_order]
        end
        embedded_file_ids = embedded_file_ids_by_page.values.flatten.uniq
        dead_foreign_file_ids = ProductFile
          .deleted
          .where(id: embedded_file_ids)
          .where.not(link_id: @product.id)
          .pluck(:id)
          .to_set

        dead_file_ids_by_page = embedded_file_ids_by_page.transform_values do |file_ids|
          file_ids.select { dead_foreign_file_ids.include?(_1) }
        end
        result = source_pages_by_external_id.transform_values do |page|
          dead_file_ids_by_page.fetch(page.external_id, [])
        end

        if legacy_destinations.any?
          stored_dead_file_ids = dead_file_ids_by_page.values.flatten.to_set
          legacy_destinations.each do |reference|
            page_id = reference[:page][:id].presence
            next if page_id.nil?

            submitted_file_ids = embedded_file_ids_in_submitted_page(reference[:page])
            removable_file_ids = submitted_file_ids.select { stored_dead_file_ids.include?(_1) }
            result[page_id] = (Array(result[page_id]) | removable_file_ids) if removable_file_ids.any?
          end
        end

        result
      end
    end

    # `source_id` is the current editor's explicit move/copy provenance. A
    # marker-less editor may instead prove a move by submitting a stored page
    # id under a different owner scope. The confirmed-id fallback remains for
    # the intermediate client that confirmed the source deletion but did not
    # yet send source_id.
    def submitted_legacy_rich_content_source_external_ids
      confirmed_ids = confirmed_removed_rich_content_ids.to_set

      (
        submitted_rich_content_page_references.filter_map do |reference|
          page = reference[:page]
          page[:source_id].presence || page[:id].presence_in(confirmed_ids)
        end +
        legacy_inferred_moved_rich_content_external_ids
      ).uniq
    end

    def rich_content_provenance_aware_request?
      params[:rich_content_provenance_version].to_i >= 1
    end

    def submitted_rich_content_page_references
      @_submitted_rich_content_page_references ||= begin
        references = Array.wrap(product_permitted_params[:rich_content]).map do |page|
          { page:, destination_entity_type: "Link", destination_entity_id: @product.id, destination_scope_key: "product" }
        end

        Array.wrap(product_permitted_params[:variants]).each_with_index do |variant, variant_index|
          destination_variant_id = decrypt_rich_content_external_id(variant[:id])
          # A brand-new variant has no server id yet, so destination_variant_id
          # is nil for every new variant in this save — falling back to it
          # alone would bucket unrelated new variants' pages into one scope
          # and falsely flag their (legitimately independent) client-generated
          # ids as colliding. The submitted array position is stable and
          # unique per variant regardless of whether it has a server id yet.
          Array.wrap(variant[:rich_content]).each do |page|
            references << {
              page:,
              destination_entity_type: "BaseVariant",
              destination_entity_id: destination_variant_id,
              destination_scope_key: destination_variant_id || "new-variant-#{variant_index}",
            }
          end
        end
        references
      end
    end

    # Resolves submitted ids and explicit source ids in one batch, then keeps
    # only pages owned by this product. Client-generated UUIDs are skipped
    # without asking the id cipher to decrypt and log them.
    def owned_submitted_rich_content_pages_by_external_id
      @_owned_submitted_rich_content_pages_by_external_id ||= begin
        external_ids = submitted_rich_content_page_references.flat_map do |reference|
          [reference[:page][:id], reference[:page][:source_id]]
        end.compact.uniq
        ids_by_external_id = external_ids.index_with do |external_id|
          decrypt_rich_content_external_id(external_id)
        end.compact
        pages_by_id = RichContent.alive.where(id: ids_by_external_id.values).index_by(&:id)

        ids_by_external_id.each_with_object({}) do |(external_id, id), result|
          page = pages_by_id[id]
          result[external_id] = page if page.present? && owned_rich_content_page?(page)
        end
      end
    end

    def legacy_inferred_moved_rich_content_external_ids
      @_legacy_inferred_moved_rich_content_external_ids ||=
        if rich_content_provenance_aware_request?
          []
        else
          references_by_page_id = submitted_rich_content_page_references
            .select { _1[:page][:source_id].blank? && _1[:page][:id].present? }
            .group_by { _1[:page][:id] }

          references_by_page_id.filter_map do |page_id, references|
            # The pre-save ambiguity guard rejects repeated ids before this
            # helper can be reached. Keep this check local too because the
            # method's result grants deletion authority to an old editor tab.
            next unless references.one?

            reference = references.sole
            stored_page = owned_submitted_rich_content_pages_by_external_id[page_id]
            next if stored_page.nil?
            next if stored_page.entity_type == reference[:destination_entity_type] &&
              stored_page.entity_id == reference[:destination_entity_id]

            stored_page.external_id
          end.uniq
        end
    end

    # An old copy used a client-generated destination id and carried no source
    # id. It reaches the bounded all-pages compatibility scan only when the
    # destination id does not address an existing page owned by this product.
    def legacy_unknown_rich_content_destinations
      return [] if rich_content_provenance_aware_request?

      submitted_rich_content_page_references.select do |reference|
        page = reference[:page]
        page[:source_id].blank? &&
          page[:id].present? &&
          owned_submitted_rich_content_pages_by_external_id[page[:id]].nil?
      end
    end

    def all_owned_alive_rich_content_pages
      @_all_owned_alive_rich_content_pages ||= begin
        product_pages = RichContent.alive.where(entity_type: "Link", entity_id: @product.id)
        variant_pages = RichContent.alive.where(entity_type: "BaseVariant", entity_id: owned_alive_variant_ids)
        product_pages.or(variant_pages).to_a
      end
    end

    def owned_rich_content_page?(page)
      (page.entity_type == "Link" && page.entity_id == @product.id) ||
        (page.entity_type == "BaseVariant" && owned_alive_variant_ids.include?(page.entity_id))
    end

    def owned_alive_variant_ids
      @_owned_alive_variant_ids ||= @product.alive_variants.pluck(:id).to_set
    end

    def decrypt_rich_content_external_id(value)
      external_id = value.to_s
      return unless external_id.match?(/\A[A-Za-z0-9_-]{22}==\z/)

      ObfuscateIds.decrypt(external_id)
    end

    def embedded_file_ids_in_submitted_page(page)
      nodes = page.dig(:description, :content)
      RichContent.new(description: Array(nodes).as_json).embedded_product_file_ids_in_order
    end

    def save_id_mappings_response
      {
        variant_id_mappings: save_id_mappings[:variants],
        rich_content_id_mappings: save_id_mappings[:rich_content],
        rich_content_id_mappings_by_scope: save_id_mappings[:rich_content_by_scope],
        file_id_mappings: save_id_mappings[:files],
        rich_content_removed_file_embed_ids: save_id_mappings[:removed_file_embeds],
        **content_updated_at_response,
        # The revision token for the state this save just committed
        # (gumroad-private#1379). Every successful save moves the product's
        # fingerprint, so the token the editor is holding — issued when the page
        # loaded — is stale the moment the first save returns. Without handing
        # back a fresh one, a seller who saves an ordinary edit and then deletes
        # a version in the same session has the deletion silently refused as
        # stale, and the row reappears on reload. The editor adopts this value
        # and echoes it on the next save.
        #
        # Emitted only while the contract is enforced: with the flag off the
        # token is meaningless and computing it would cost the fingerprint
        # queries on every save for no benefit.
        **editor_revision_response,
      }
    end

    # The snapshot token for the state this save just produced, so the editor's
    # NEXT save can still delete. Every save moves the fingerprint (it writes
    # rows, and the token now covers child updated_at as well as ids), so a
    # session that kept its original token would find itself stale the moment it
    # saved once — the second deletion in a session would be silently refused.
    #
    # Only emitted when the contract is enforced: with the flag off the client
    # has no use for it, and computing it would put the fingerprint queries back
    # on the default path that must stay free of them.
    def editor_revision_response
      return {} unless product_save_contract.enforced?

      {
        editor_revision: Product::EditorRevision.current(@product.reload),
        # The integrations baseline for the state this save just committed.
        #
        # Same staleness problem as the token, different symptom. The baseline
        # says which integrations were connected when the session loaded, and
        # the client asks to disconnect one only if it was in that baseline and
        # is now off. If the baseline is never refreshed, an integration that
        # was CONNECTED during this session (connect -> save) is still recorded
        # as "was off at load", so turning it off and saving again emits no
        # deletion at all and the integration silently survives.
        loaded_integrations: current_integrations_baseline,
        # The same refresh, per version. Without it the version-scoped baseline
        # goes stale in exactly the way the product-level one did: enable an
        # integration on a tier, save, switch it off, save again — and the
        # second save emits no version-scoped deletion because the tier is
        # still recorded as "was off at load".
        variant_loaded_integrations: current_variant_integrations_baseline,
      }
    end

    # Per-variant connected/not-connected snapshot, keyed by variant external
    # id. Mirrors what ProductPresenter issues for each variant on page load.
    def current_variant_integrations_baseline
      @product.reload.alive_variants.each_with_object({}) do |variant, acc|
        acc[variant.external_id] = Integration::ALL_NAMES.index_with { |name| variant.find_integration_by_name(name).present? }
      end
    end

    # Which integrations are connected right now, keyed by provider name. Same
    # shape and source of truth as ProductPresenter#edit_props issues on page
    # load, so the client can swap one for the other without special-casing.
    def current_integrations_baseline
      Integration::ALL_NAMES.index_with { @product.find_integration_by_name(_1).present? }
    end

    # Fresh post-save snapshot timestamps for every alive page and variant,
    # keyed by external id. The editor adopts these so its NEXT save echoes
    # the timestamps this save produced — without this, the session's second
    # save would echo pre-save timestamps and reject itself as stale.
    # Queried fresh (reload / current_base_variants builds a new relation):
    # the save steps above created and soft-deleted rows through the cached
    # association, so the cached copy no longer reflects what's alive.
    # Variants report the same combined row+prices timestamp the guard compares
    # against (Product::StaleContentWriteGuard.snapshot_at), so a save that
    # only changed a membership tier's prices still refreshes the session's
    # snapshot.
    def content_updated_at_response
      pages = @product.alive_rich_contents.reload.to_a +
        @product.current_base_variants.flat_map { _1.alive_rich_contents.to_a }
      {
        rich_content_updated_at: pages.to_h { [_1.external_id, _1.updated_at] },
        variant_updated_at: @product.current_base_variants.to_h { [_1.external_id, Product::StaleContentWriteGuard.snapshot_at(_1)] },
      }
    end

    # Every content-bearing version-level page the submitted save didn't
    # account for — the full set a hidden-content conflict asks the seller to
    # decide about. Queried fresh (current_base_variants builds a new relation)
    # because the failed save's transaction has been rolled back and cached
    # associations may still carry its in-memory deletions.
    def all_hidden_variant_pages
      @product.current_base_variants.flat_map do |variant|
        variant.alive_rich_contents.select(&:has_editor_content?)
      end.reject do |rich_content|
        payload_page_ids.include?(rich_content.external_id) ||
          confirmed_removed_rich_content_ids.include?(rich_content.external_id) ||
          preserved_rich_content_ids.include?(rich_content.external_id)
      end.map { { id: _1.external_id, title: _1.title, variant_name: _1.entity.name } }
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

    def update_default_offer_code
      default_offer_code_id = product_permitted_params[:default_offer_code_id]

      return @product.default_offer_code = nil if default_offer_code_id.blank?

      offer_code = @product.user.offer_codes.alive.find_by_external_id!(default_offer_code_id)

      raise Link::LinkInvalid, "Offer code cannot be expired" if offer_code.inactive?
      raise Link::LinkInvalid, "Offer code must apply to this product" unless offer_code.applicable?(@product)

      @product.default_offer_code = offer_code
    rescue ActiveRecord::RecordNotFound
      raise Link::LinkInvalid, "Invalid offer code"
    end

    def toggle_community_chat!(enabled)
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
        ErrorNotifier.notify(e)
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
        ErrorNotifier.notify(e)
      end
    end

    def render_custom_html_if_present
      return unless custom_html_visible?
      # The public JSON API (GET /l/:permalink.json) must return the documented
      # product payload, not the custom-HTML landing page — only intercept HTML.
      return unless request.format.html?
      # Buyer clicked Buy — fall through to the show action's checkout-bearing
      # product page so the existing ?wanted=true flow handles the redirect.
      return if params[:wanted] == "true"

      nonce = SecureHeaders.content_security_policy_script_nonce(request)
      render html: custom_html_wrapper_document(@product, nonce:, offer_code: params[:offer_code].presence || params[:code].presence).html_safe, layout: false
    end

    def custom_html_document(custom_html)
      <<~HTML
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            #{SANDBOX_COMPAT_SCRIPT}
            #{self.class.pages_tailwind_head}
            #{self.class.tailwind_v3_gradient_compat_head(custom_html)}
          </head>
          <body>
            #{custom_html}
            <script data-cfasync="false">
              document.addEventListener("click", function (e) {
                var target = e.target;
                var buyButton = target && target.closest ? target.closest('[data-gumroad-action="buy"]') : null;
                if (!buyButton) return;
                e.preventDefault();

                var params = {};
                try {
                  params = JSON.parse(buyButton.dataset.gumroadCheckoutParams || "{}");
                } catch (_e) {}

                parent.postMessage({type:"gumroad:checkout",params:params},"*");
              }, true);
            </script>
            #{custom_html_navigation_bridge_script(allowed_hostnames: product_store_hostnames)}
            #{BACKGROUND_BRIDGE_SCRIPT}
          </body>
        </html>
      HTML
    end

    # Hostnames the product landing page's navigation bridge accepts as "this
    # seller's own store". Same shape as the profile's allowlist (see
    # UsersController#profile_store_hostnames): only hosts this seller
    # controls, never a shared Gumroad host, so the sandboxed seller HTML can
    # never navigate the visitor's tab to arbitrary gumroad.com paths. Product
    # links the seller writes point at their subdomain (Link#long_url), so a
    # visitor browsing the custom domain still needs the subdomain
    # allowlisted for those links to bridge.
    def product_store_hostnames
      user = @product&.user
      return [] if user.nil?

      hostnames = []
      hostnames << request.host unless VALID_REQUEST_HOSTS.include?(request.host)
      hostnames.concat(user.custom_html_store_hostnames)
      hostnames.compact.uniq
    end

    # Omitting `allow-same-origin` keeps the seller's HTML on an opaque origin
    # — no access to gumroad.com cookies or parent DOM. We also omit
    # `allow-top-navigation`: the seller's HTML must never navigate the buyer's
    # tab (that would let a malicious onclick redirect to a phishing site with
    # gumroad.com still in the URL bar). Instead the buy button posts a message
    # to this wrapper, which navigates to the one checkout URL we control here,
    # and links to the seller's own Gumroad pages post `gumroad:navigate`,
    # which this wrapper re-validates against the seller's own hostnames
    # before navigating the top-level window. Without that second bridge a
    # plain in-page link to the seller's storefront or another of their
    # products could only work as `target="_blank"` — anything same-tab was
    # blocked by the sandbox and the visitor landed on an error page.
    def custom_html_wrapper_document(product, nonce:, offer_code: nil)
      iframe_src = ERB::Util.h("/l/#{product.unique_permalink}/landing/embed")
      checkout_params = { wanted: true }
      checkout_params[:code] = offer_code if offer_code.present?
      checkout_url_js = ERB::Util.json_escape("/l/#{product.unique_permalink}?#{Rack::Utils.build_query(checkout_params)}".to_json)
      store_hostnames_js = ERB::Util.json_escape(product_store_hostnames.to_json)
      title = ERB::Util.h(product.name.to_s)
      canonical = ERB::Util.h(product.long_url(host: custom_domain_host_for_meta(product)).to_s)
      # The wrapper is what search engines see at the canonical /l/<permalink>
      # URL — the seller's HTML lives in a sandboxed, opaque-origin iframe whose
      # content crawlers generally do NOT attribute to this page. Without the
      # tags below, going custom made a product invisible to search (no meta
      # description, no structured data, empty body). Mirror the standard
      # product page's SEO signals here: same description source
      # (PageMeta::Product) and the same JSON-LD (Product::StructuredData).
      # All of this is trusted, Gumroad-authored data rendered in the trusted
      # wrapper — none of it comes from the seller's custom HTML.
      # `.presence` on the plaintext (not the raw description) so markup-only
      # descriptions like "<p><br></p>" — present as raw HTML but empty once
      # stripped to text — still fall back instead of emitting empty tags.
      description = product.plaintext_description.presence || "Available on Gumroad"
      # plaintext_description comes back from the Rails sanitizer, which strips
      # tags and entity-encodes &/</> for text context but does NOT escape
      # double quotes — and ERB::Util.h passes html_safe strings through
      # untouched. Escape quotes explicitly so a description containing `"`
      # can't break out of the meta tag's attribute value.
      description_attr = description.gsub('"', "&quot;")
      structured_data = product.structured_data(host: custom_domain_host_for_meta(product))
      # json_escape keeps the JSON valid while escaping <, >, & so a
      # description containing "</script>" can't break out of the script tag.
      structured_data_tag = if structured_data.any?
        %(<script type="application/ld+json">#{ERB::Util.json_escape(structured_data.to_json)}</script>)
      else
        ""
      end
      # Thumbnail first (the wrapper's original image source, kept as the
      # winner), then the standard product page's fallback chain — cover image,
      # then the thumbnail of a video/oembed cover — via
      # Link#social_share_image. Without the fallbacks, products with a
      # cover but no thumbnail (the common case) lost their link-preview image
      # the moment they went custom (gumroad-private#1122).
      share_image = product.thumbnail&.alive&.url || product.social_share_image
      share_image_tags = if share_image
        escaped_share_image = ERB::Util.h(share_image)
        %(<meta property="og:image" content="#{escaped_share_image}">\n    <meta property="twitter:card" content="summary_large_image">\n    <meta property="twitter:image" content="#{escaped_share_image}">)
      else
        ""
      end
      <<~HTML
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>#{title}</title>
            <link rel="canonical" href="#{canonical}">
            <meta name="description" content="#{description_attr}">
            <meta property="og:title" content="#{title}">
            <meta property="og:description" content="#{description_attr}">
            <meta property="og:type" content="product">
            <meta property="og:url" content="#{canonical}">
            #{share_image_tags}
            #{structured_data_tag}
            <meta name="csrf-token" content="#{ERB::Util.h(form_authenticity_token)}">
            #{custom_html_analytics_head(product)}
            <style>html,body{margin:0;padding:0;height:100%;overflow:hidden}iframe{display:block;width:100%;height:100%;border:0}.seo-summary{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}</style>
          </head>
          <body>
            <div class="seo-summary">
              <h1>#{title}</h1>
              <p>#{description}</p>
            </div>
            <iframe
              id="gumroad-landing-frame"
              src="#{iframe_src}"
              title="#{title}"
              sandbox="#{CUSTOM_HTML_SANDBOX}"
            ></iframe>
            <script nonce="#{ERB::Util.h(nonce)}" data-cfasync="false">
              var frame = document.getElementById("gumroad-landing-frame");
              var BASE_CHECKOUT = #{checkout_url_js};
              // Hosts this seller controls. A "gumroad:navigate" message is only
              // honored for these, so the untrusted iframe can never send the
              // visitor's tab off to a phishing site with gumroad.com still in
              // the URL bar.
              var STORE_HOSTNAMES = #{store_hostnames_js};
              #{custom_html_navigation_allowlist_js.indent(14).strip}
              // Whitelist the selection-state keys the checkout already accepts on the
              // URL (see LinksController#show). The iframe is opaque-origin and untrusted,
              // so anything not in this list is ignored even if the buy button claims it.
              var ALLOWED_CHECKOUT_KEYS = ["variant","option","quantity","price","recurrence"];
              function buildCheckoutUrl(base, params) {
                if (!params || typeof params !== "object") return base;
                try {
                  var u = new URL(base, window.location.origin);
                  for (var i = 0; i < ALLOWED_CHECKOUT_KEYS.length; i++) {
                    var k = ALLOWED_CHECKOUT_KEYS[i], v = params[k];
                    if (v == null || v === "") continue;
                    u.searchParams.set(k, String(v));
                  }
                  return u.pathname + u.search;
                } catch (_e) { return base; }
              }
              window.addEventListener("message", function (e) {
                if (e.source !== frame.contentWindow || e.origin !== "null") return;
                // String form: back-compat for any caller still sending the old signal.
                if (e.data === "gumroad:checkout") { window.location.href = BASE_CHECKOUT; return; }
                // Structured form: {type:"gumroad:checkout", params:{variant,quantity,price,recurrence}}.
                if (e.data && typeof e.data === "object" && e.data.type === "gumroad:checkout") {
                  window.location.href = buildCheckoutUrl(BASE_CHECKOUT, e.data.params);
                  return;
                }
                // Same-tab navigation to the seller's own Gumroad pages (their
                // storefront, their other products) and to Gumroad's blessed
                // account/cart paths. The sandbox deliberately withholds
                // top-level navigation from the iframe, so a plain link inside
                // the page can't do this itself — it asks here and we
                // re-validate the destination.
                if (e.data && typeof e.data === "object" && e.data.type === "gumroad:navigate" && typeof e.data.url === "string") {
                  var url;
                  try { url = new URL(e.data.url, window.location.href); } catch (_err) { return; }
                  if (url.protocol !== "https:" && url.protocol !== "http:") return;
                  var destination = gumroadNavigationTarget(url, STORE_HOSTNAMES);
                  if (destination === null) return;
                  window.location.href = destination;
                }
              });
            </script>
            #{custom_html_background_wrapper_script(nonce:)}
            #{can_preview_custom_html? ? custom_html_live_reload_script(version_src: "/l/#{product.unique_permalink}/landing/version", nonce:) : ""}
          </body>
        </html>
      HTML
    end

    # Custom HTML pages bypass the React product page, so the seller's analytics
    # (Google Analytics, Facebook/TikTok pixels, and raw third-party snippets)
    # never load. We inject them into the trusted wrapper — never the sandboxed
    # landing iframe, whose strict CSP (connect-src 'none', no Google host in
    # script-src) blocks them by design. The wrapper runs under the global site
    # CSP, which allowlists those hosts, and the `custom_html_analytics` entry
    # point reuses the same tracking modules the standard product page uses.
    #
    # The entry point fires the same events the standard product page would
    # (product view + "I want this" on buy click) so switching to a custom page
    # keeps the same analytics event names. begin_checkout and purchase stay on
    # the standard checkout and receipt pages the buy button navigates to, which
    # already fire them — firing them here too would double-count.
    def custom_html_analytics_head(product)
      tracking_enabled = analytics_enabled?(seller: product.user)
      analytics = product.analytics_data
      # When third-party tracking is off, blank the pixel ids before they reach
      # the props JSON. The frontend never uses them in that case (every pixel
      # call is gated on tracking_enabled), but without this a seller who
      # disabled third-party analytics would still see their Google/Facebook/
      # TikTok ids embedded in the page source for anyone to inspect.
      analytics = analytics.merge(google_analytics_id: nil, facebook_pixel_id: nil, tiktok_pixel_id: nil) unless tracking_enabled
      has_product_third_party_analytics = tracking_enabled && product.has_third_party_analytics?("product")
      has_configured_pixel = tracking_enabled && analytics.values_at(:google_analytics_id, :facebook_pixel_id, :tiktok_pixel_id).any?(&:present?)

      props = {
        seller_id: product.user.external_id,
        analytics:,
        tracking_enabled:,
        has_product_third_party_analytics:,
        third_party_analytics_domain: THIRD_PARTY_ANALYTICS_DOMAIN,
        permalink: product.unique_permalink,
        name: product.name,
      }

      # The pixel meta tags render only when tracking is enabled and the seller has
      # at least one pixel id configured. All three enabled flags are "true" rather
      # than per-pixel because the frontend gates each pixel on its own configured
      # id — mirroring PageMeta::Analytics#set_analytics_meta_tags, which the
      # wrapper's layout-less document can't accumulate. The props JSON goes in a
      # double-quoted attribute, so ERB::Util.h (which escapes ") is the right escape
      # here — json_escape would leave quotes intact and break out of the attribute.
      pixel_meta_tags = if has_configured_pixel
        <<~HTML
          <meta property="gr:google_analytics:enabled" content="true">
          <meta property="gr:fb_pixel:enabled" content="true">
          <meta property="gr:tiktok_pixel:enabled" content="true">
        HTML
      else
        ""
      end

      <<~HTML.strip
        #{pixel_meta_tags}
        <meta name="gr:custom-html-analytics" content="#{ERB::Util.h(props.to_json)}">
        #{helpers.vite_typescript_tag("custom_html_analytics")}
      HTML
    end
end
