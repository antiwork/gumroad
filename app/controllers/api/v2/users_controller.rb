# frozen_string_literal: true

class Api::V2::UsersController < Api::V2::BaseController
  # Where the SellerProfile theme columns actually render, verified against every caller of
  # SellerProfile#custom_styles. Listed in the theme response because the single most costly wrong
  # belief about this feature is that it only styles the profile page: it styles product pages too,
  # and an agent that assumes otherwise contradicts a seller who is looking straight at their own
  # themed product page. Note the deliberate narrowness on emails — only the posts a seller sends
  # to their audience carry the theme; Gumroad's own transactional mail (receipts and the like)
  # does not.
  THEME_SURFACES = [
    "storefront profile page",
    "product pages",
    "the checkout page, but only when every product being bought is this seller's",
    "the pages buyers see for products they bought",
    "posts",
    "the emails a seller sends to their audience",
  ].freeze

  before_action -> { doorkeeper_authorize!(*Doorkeeper.configuration.public_api_read_scopes.concat([:view_public])) }, only: [:show, :ifttt_sale_trigger, :custom_html, :theme]
  before_action(only: [:profile_layout]) { doorkeeper_authorize! :view_profile }
  before_action(only: [:profile_layout]) { require_oauth_scope! :view_profile }
  before_action(only: [:update, :update_custom_html, :edit_custom_html, :preview_custom_html]) { doorkeeper_authorize! :edit_profile }
  before_action :ensure_custom_html_pages_enabled, only: [:custom_html, :update_custom_html, :edit_custom_html, :preview_custom_html]

  def show
    if params[:is_ifttt]
      user = current_resource_owner
      user.name = current_resource_owner.email if user.name.blank?
      return success_with_object(:data, user)
    end

    success_with_object(:user, current_resource_owner)
  end

  def update
    user = current_resource_owner

    return render_response(false, message: "You have to confirm your email address before you can do that.") unless user.confirmed?

    if user.update(permitted_update_params)
      success_with_object(:user, user)
    else
      error_with_object(:user, user)
    end
  end

  # GET the seller's own profile landing page HTML. has_landing_page lets the
  # agent decide whether it's editing an existing page or authoring a new one.
  #
  # rendered_html is the pull path for going custom: a faithful standalone-HTML
  # render of the profile as it serves today. When no custom HTML is published
  # yet, that's a render of the default storefront (creator header, product
  # grid, posts) — so an agent taking over the home page starts from what the
  # profile already looks like instead of a blank file. Once custom HTML is
  # live, the stored HTML already IS the document, so it's returned as-is.
  # Slugged pages have the same field on GET /v2/pages/:slug.
  def custom_html
    user = current_resource_owner
    rendered_html = user.custom_html.presence || Pages::DefaultProfileDocument.render(user)
    render_response(true, custom_html: user.custom_html, rendered_html:, has_landing_page: user.has_custom_landing_page?, profile_url: profile_url_for(user))
  end

  # PUT the profile landing page. Mirrors the product custom_html surface but is
  # profile-scoped and drops the buy-affordance warning — a profile has no
  # native checkout, so its custom HTML is never expected to carry a buy element.
  def update_custom_html
    user = current_resource_owner

    return render_response(false, message: "You have to confirm your email address before you can do that.") unless user.confirmed?
    return render_response(false, message: "custom_html is required.") unless params.key?(:custom_html)

    if !params[:custom_html].nil? && !params[:custom_html].is_a?(String)
      return render_response(false, message: "custom_html must be a string.")
    end

    if (length_error = custom_html_length_error)
      return render_response(false, message: length_error)
    end

    begin
      result = Pages::CustomHtmlWriter.replace!(user, params[:custom_html])
    rescue ActiveRecord::RecordInvalid => e
      return error_with_object(:user, e.record)
    end

    render_response(true, custom_html: result.custom_html, previous_custom_html: result.previous_custom_html, sanitization_report: result.sanitization_report, profile_url: profile_url_for(user))
  end

  # POST a targeted edit to the profile landing page: replaces exactly one occurrence of the
  # `find` snippet with `replace` inside the existing custom HTML, leaving the rest of the page
  # untouched, then re-sanitizes and saves the full result.
  #
  # This exists so the store agent can make a small change (a color, a button label, a heading)
  # without regenerating the whole page. Before this endpoint, the agent's only write surface was
  # a full-page replacement (update_custom_html), so a seller asking for a tiny tweak could lose
  # their entire hand-built storefront page to a fresh, much smaller regeneration.
  def edit_custom_html
    user = current_resource_owner

    return render_response(false, message: "You have to confirm your email address before you can do that.") unless user.confirmed?

    find = params[:find]
    replace = params[:replace]
    unless find.is_a?(String) && find.present?
      return render_response(false, message: "find is required and must be a non-empty string copied exactly from the current custom HTML.")
    end
    unless replace.is_a?(String)
      return render_response(false, message: "replace is required and must be a string (use \"\" to delete the snippet).")
    end

    begin
      result = Pages::CustomHtmlWriter.edit!(user, find:, replace:)
    rescue ActiveRecord::RecordInvalid => e
      return error_with_object(:user, e.record)
    end

    return render_response(false, message: result.error) unless result.success?

    render_response(true, custom_html: result.custom_html, previous_custom_html: result.previous_custom_html, sanitization_report: result.sanitization_report, profile_url: profile_url_for(user))
  end

  # Dry-run sanitize: returns what custom_html would look like after the
  # sanitizer runs, without writing. Lets the agent iterate without rewriting
  # the live page every attempt. Mirrors update_custom_html's blank-to-nil
  # normalization so the dry-run and the real PUT agree on edge cases.
  def preview_custom_html
    return render_response(false, message: "custom_html is required.") unless params.key?(:custom_html)

    custom_html = params[:custom_html]
    return render_response(false, message: "custom_html must be a string.") unless custom_html.nil? || custom_html.is_a?(String)

    if (length_error = custom_html_length_error)
      return render_response(false, message: length_error)
    end

    result = Ai::PageSanitizer.sanitize_with_report(custom_html)
    sanitized = result.html.presence
    candidate_page = validate_custom_html_preview_candidate(current_resource_owner, sanitized)
    # :base as well as :custom_html: moderation reports on :base, and a preview
    # that ignored it would call a page publishable that the real write rejects.
    errors = candidate_page.errors.where(:custom_html) + candidate_page.errors.where(:base)

    if errors.any?
      render_response(false, message: errors.map(&:full_message).to_sentence, sanitization_report: result.report)
    else
      render_response(true, custom_html: sanitized, sanitization_report: result.report)
    end
  end

  def ifttt_status
    render json: { status: "success" }
  end

  # The seller's store theme: the background colour, highlight (accent) colour, and font stored on
  # their SellerProfile. Read-only here: sellers edit these directly in Settings > Profile > Design,
  # while the agent can read them and point the seller to that screen.
  # The theme is not profile-page-only: the same values render into the stylesheet served with the
  # storefront, every product page, checkout when the cart is all one seller's, the pages buyers see
  # for what they bought, posts, and the emails a seller sends to their own audience — see
  # THEME_SURFACES.
  def theme
    profile = current_resource_owner.seller_profile

    render_response(
      true,
      theme: {
        background_color: profile.background_color,
        highlight_color: profile.highlight_color,
        font: profile.font,
        applies_to: THEME_SURFACES,
        editable_by_seller: true,
        how_to_change: "The seller changes these themselves in Settings > Profile > Design, which previews the change before saving.",
      }
    )
  end

  # The layout of the seller's DEFAULT (non-custom-HTML) storefront profile: the tabs they created
  # in the profile editor and the sections inside them, each with its heading.
  #
  # Read-only, and it exists purely so a caller can see this surface at all. The store agent could
  # previously read only the profile's custom HTML, so for a seller who has never published custom
  # HTML it saw nothing and concluded the storefront was Gumroad's untouched default. A seller who
  # then asked about a heading they could see on their own page — a section header they typed
  # themselves — was told it did not exist, that the default template had a different heading, and
  # that their browser cache was to blame (gumroad-private#1466). Headings on the default profile
  # come from `SellerProfileSection#header`, so they are readable; nothing was wrong except the
  # blindness.
  #
  # Writes stay out: the section editor is a structured, drag-and-drop surface the seller owns, and
  # the agent's only appearance write path is deliberately custom HTML (gumroad-private#984).
  def profile_layout
    seller = current_resource_owner
    profile = seller.seller_profile
    sections = seller.seller_profile_sections.on_profile.to_a
    sections_by_id = sections.index_by(&:id)
    tabs = profile.json_data["tabs"] || []
    if ProfileSectionsPresenter.default_products_section_available?(seller:, sections:)
      tabs = [{
        "name" => ProfileSectionsPresenter::DEFAULT_PRODUCTS_TAB_NAME,
        "sections" => [ProfileSectionsPresenter::DEFAULT_PRODUCTS_SECTION_ID],
      }]
    end

    render_response(
      true,
      profile_layout: {
        # The profile root custom HTML takes over the whole storefront when present, in which case
        # none of the tabs/sections below are rendered. Say which one the buyer actually sees so a
        # caller does not describe a layout that is not on screen.
        rendering: seller.custom_landing_page_visible? ? "custom_html" : "tabs_and_sections",
        # The public profile hides the tab bar entirely while there is only one tab
        # (Profile/index.tsx). A seller who made exactly one named tab sees its sections render with
        # the name nowhere, which reads as "my page didn't save" — so state it rather than leaving a
        # caller to infer it.
        tab_bar_visible: tabs.length > 1,
        tabs: tabs.map do |tab|
          {
            name: tab["name"],
            sections: (tab["sections"] || []).filter_map do |section_id|
              if section_id == ProfileSectionsPresenter::DEFAULT_PRODUCTS_SECTION_ID
                {
                  header: nil,
                  type: ProfileSectionsPresenter::DEFAULT_PRODUCTS_SECTION_TYPE,
                }
              else
                section = sections_by_id[section_id]
                next if section.nil?

                {
                  # The heading text rendered as an <h2> above the section, when the seller set one
                  # and did not hide it. This is the field that answers "where is this heading coming
                  # from?".
                  header: section.hide_header? ? nil : section.header.presence,
                  type: section.type,
                }
              end
            end,
          }
        end,
        editable_by_seller: true,
        how_to_change: "The seller edits these in the dashboard under Settings > Profile. You have no endpoint for them — you can read this layout but not change it.",
      }
    )
  end

  def ifttt_sale_trigger
    limit = params[:limit] || 50

    sales = current_resource_owner.sales
      .successful_or_preorder_authorization_successful
      .includes(:link, :purchaser)

    sales = if params[:after].present?
      sales.where("created_at >= ?", Time.zone.at(params[:after].to_i))
           .order("created_at ASC").limit(limit)
    elsif params[:before].present?
      sales.where("created_at <= ?", Time.zone.at(params[:before].to_i))
           .order("created_at DESC").limit(limit)
    else
      sales.order("created_at DESC").limit(limit)
    end

    sales = sales.map(&:as_json_for_ifttt)

    success_with_object(:data, sales)
  end

  private
    def permitted_update_params
      params.permit(:name, :bio)
    end

    def ensure_custom_html_pages_enabled
      return if Feature.active?(:custom_html_pages, current_resource_owner)

      render_response(false, message: "You do not have access to custom HTML pages.")
    end

    # Where the published page is live. Nil for the rare seller without a
    # username (no public profile yet), since profile_url has nothing to build.
    def profile_url_for(user)
      user.username.present? ? user.profile_url : nil
    end
end
