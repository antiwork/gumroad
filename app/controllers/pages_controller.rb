# frozen_string_literal: true

# First-class Pages (gumroad-private#1047): the seller-facing management UI.
#
# The list shows the seller's public profile pinned as the special "home" entry
# plus every slugged page; the editor is a title + rich text form with a live
# preview. Pages built as full custom HTML by an agent/CLI show a preview and
# the agent path instead of the rich text editor — there is no lossy
# HTML → rich text conversion.
class PagesController < Sellers::BaseController
  include RendersCustomHtmlPages
  include CurrencyHelper
  include PageMeta::User

  layout "inertia"

  SEO_MAX_LENGTHS = { title: Page::MAX_SEO_TITLE_LENGTH, description: Page::MAX_SEO_DESCRIPTION_LENGTH }.freeze

  before_action :set_page, only: [:edit, :update, :destroy, :preview, :products]
  # The seller reaches the preview straight off a save, so a replica read can serve a slice
  # that disagrees with the freshly-rendered first page — same reason the public landing
  # endpoints pin.
  around_action :use_primary_for_landing_iframe, only: [:products]

  def index
    authorize :page

    render inertia: "Pages/Index", props: {
      pages: current_seller.pages.map { page_props(_1) },
      profile: profile_entry,
      # Product pages are edited from each product's Share tab, not here. The
      # list shows a row linking to Products so a seller whose agent built a
      # custom product page doesn't look in Pages and think it's gone — but
      # only once at least one live product actually has one (mirroring how
      # the Home row waits for a first page), so the count is custom pages,
      # not products.
      product_pages_count: Page.roots.where(pageable_type: "Link", pageable_id: current_seller.links.alive.select(:id))
                               .where.not(custom_html: nil).count,
    }
  end

  def new
    authorize :page

    render inertia: "Pages/Edit", props: {
      page: { slug: nil, title: "", content: "", custom_html: false, seo_title: "", seo_description: "",
              default_seo_title: current_seller.name_or_username, default_seo_description: nil },
      is_profile: false,
      is_new: true,
      username: current_seller.username.to_s,
      profile_url: current_seller.profile_url,
      products_page_limit: Pages::ProfileData::MAX_ITEMS,
      seo_max_lengths: SEO_MAX_LENGTHS,
      seller_name: current_seller.name_or_username,
    }
  end

  def create
    authorize :page

    page = current_seller.pages.build(title: params[:title].to_s.strip, content: params[:content].to_s, **seo_params)
    page.slug = generate_slug(page.title)

    if page.save
      redirect_to edit_page_path(page.slug), notice: "Page created!", status: :see_other
    else
      redirect_to new_page_path, inertia: { errors: page_errors(page) }
    end
  end

  def edit
    authorize :page

    if @profile_page
      # The profile is the special root page: it renders the default storefront
      # template (product grid, follow form, tabs), with the details edited in
      # profile settings. Sellers keep it 100% customizable by replacing it
      # with fully custom HTML via their agent or the CLI, so the editor
      # renders the template view with that takeover path.
      # "Home" matches the pinned entry in the Pages list — the same page
      # shouldn't change names between the list, the editor header, and the
      # preview pane.
      render inertia: "Pages/Edit", props: {
        page: {
          slug: "profile",
          title: "Home",
          content: "",
          custom_html: current_seller.custom_html.present?,
          seo_title: current_seller.seller_profile.seo_title.to_s,
          seo_description: current_seller.seller_profile.seo_description.to_s,
          default_seo_title: current_seller.name_or_username,
          default_seo_description: profile_meta_description(current_seller),
        },
        is_profile: true,
        is_new: false,
        username: current_seller.username.to_s,
        profile_url: current_seller.profile_url,
        products_page_limit: Pages::ProfileData::MAX_ITEMS,
        seo_max_lengths: SEO_MAX_LENGTHS,
        seller_name: current_seller.name_or_username,
      }
      return
    end

    render inertia: "Pages/Edit", props: {
      page: page_props(@page),
      is_profile: false,
      is_new: false,
      username: current_seller.username.to_s,
      profile_url: current_seller.profile_url,
      products_page_limit: Pages::ProfileData::MAX_ITEMS,
      seo_max_lengths: SEO_MAX_LENGTHS,
      seller_name: current_seller.name_or_username,
    }
  end

  def update
    authorize :page

    if @profile_page
      # The profile entry supports two edits here: removing a custom HTML
      # takeover, which restores the default storefront template, and its
      # search fields. Everything else about the profile is edited in profile
      # settings.
      if params[:remove_custom_html]
        current_seller.custom_html = nil
        current_seller.save!
        return redirect_to edit_page_path("profile"), notice: "Custom page removed — your profile is back on the default template.", status: :see_other
      end
      return redirect_to pages_path if seo_params.empty?

      # Same lock as profile settings, so a first profile save can't create a
      # second row for the seller.
      seller_profile = nil
      saved = current_seller.with_locked_seller_profile do |profile|
        seller_profile = profile
        profile.update(seo_params)
      end
      return redirect_to edit_page_path("profile"), notice: "Changes saved!", status: :see_other if saved

      return redirect_to edit_page_path("profile"), inertia: { errors: page_errors(seller_profile) }
    end

    # A custom HTML page is authored by the seller's agent/CLI; the in-app
    # editor never writes over its title or content (the UI doesn't offer to,
    # this is the server-side backstop). Its SEO fields are editable here.
    attributes = @page.custom_html.present? ? {} : { title: params[:title].to_s.strip, content: params[:content].to_s }
    if @page.update(attributes.merge(seo_params))
      redirect_to edit_page_path(@page.slug), notice: "Changes saved!", status: :see_other
    else
      redirect_to edit_page_path(@page.slug), inertia: { errors: page_errors(@page) }
    end
  end

  def destroy
    authorize :page

    return redirect_to pages_path if @profile_page

    @page.destroy!
    redirect_to pages_path, notice: "Page deleted!", status: :see_other
  end

  # Renders a page for the editor's preview pane, same-origin. The public page
  # can't be framed here: it's a wrapper whose nested embed responds with
  # X-Frame-Options: SAMEORIGIN, and the dashboard is a different origin than
  # the seller's subdomain, so the browser blocks the frame.
  #
  # - Rich text pages render the same styled document the public page serves
  #   (Pages::RichTextDocument), so the preview shows the real page — title,
  #   byline, typography — not the editor's raw HTML.
  # - Custom HTML pages render the sanitized document with the same strict
  #   CSP + sandbox headers as the public embed (the editor's iframe adds its
  #   own sandbox attribute on top).
  def preview
    authorize :page

    custom_html = @profile_page ? current_seller.custom_html : @page.custom_html
    if custom_html.blank?
      # The profile's default template is framed live from the storefront, so
      # there is nothing for this endpoint to render for it.
      return head :not_found if @profile_page

      return render html: Pages::RichTextDocument.render(page: @page, seller_name: current_seller.name_or_username, profile_href: current_seller.profile_url),
                    layout: false
    end

    apply_custom_html_response_headers
    # The profile page's live embed serves the gumroad-data catalog and (when referenced) the
    # per-request gumroad-prices payload, so its editor preview must too — without them a page
    # that builds its cards from those scripts previews as an empty storefront. Slugged pages
    # are served without either payload, so their preview stays payload-free to match.
    # No navigation bridge in either branch: the editor pane has no trusted wrapper listening.
    # The follow bridge IS included — without it a data-gumroad-follow form would
    # native-submit and navigate the preview frame away, which reads as "the form is broken".
    # The products bridge is answered here for real: see #products.
    if @profile_page
      # The prices are derived from the requester's IP, so this response must never be shared.
      response.cache_control.replace(private: true, no_store: true)
      prices_referenced = Pages::ProductPrices.referenced_in?(custom_html)
      prices = prices_referenced ? Pages::ProductPrices.build(current_seller, ip: request.remote_ip, preferred_currency: buyer_currency_preference(request)) : {}
      interpolated = Pages::Interpolator.interpolate_profile(custom_html, profile: current_seller, prices:)
      render html: profile_custom_html_document(
        interpolated,
        data_json: ERB::Util.json_escape(Pages::ProfileData.build(current_seller).to_json),
        prices_json: prices_referenced ? ERB::Util.json_escape(prices.to_json) : nil,
        follow_bridge: FOLLOW_BRIDGE_SCRIPT,
        # The editor pane's own products wrapper answers these (see #products) —
        # a page whose cards come from a catalogue slice has to render in the
        # preview too, or the seller can only test it by publishing.
        products_bridge: PRODUCTS_BRIDGE_SCRIPT,
      ).html_safe, layout: false
    else
      interpolated = Pages::Interpolator.interpolate_profile(custom_html, profile: current_seller)
      render html: <<~HTML.html_safe, layout: false
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            #{SANDBOX_COMPAT_SCRIPT}
            #{self.class.pages_tailwind_head}
            #{self.class.tailwind_v3_gradient_compat_head(interpolated)}
          </head>
          <body>
            #{interpolated}
            #{FOLLOW_BRIDGE_SCRIPT}
          </body>
        </html>
      HTML
    end
  end

  # Catalogue slices for the editor preview's products bridge. The preview pane's
  # wrapper (LandingPagePreview-style listener in Pages/Edit) fetches this instead of
  # the public /landing/products endpoint: the preview renders the seller's UNSAVED
  # profile takeover from the dashboard origin, where that endpoint is not routed and
  # the seller may not even have a visible custom page yet. Always the signed-in
  # seller's own catalogue — the slice params can't pick an account.
  def products
    authorize :page

    return head :not_found unless @profile_page

    render_custom_html_products_slice(current_seller)
  end

  private
    def set_page
      if params[:slug] == "profile"
        @profile_page = true
        return
      end

      @page = current_seller.pages.find_by(slug: params[:slug])
      redirect_to pages_path unless @page
    end

    def page_props(page)
      {
        slug: page.slug,
        title: page.title.to_s,
        content: page.content.to_s,
        custom_html: page.custom_html.present?,
        seo_title: page.seo_title.to_s,
        seo_description: page.seo_description.to_s,
        # What the page shows when the seller leaves a field blank. The editor
        # recomputes the title default from seller_name while the title changes.
        default_seo_title: Pages::DocumentTitle.for(page_title: page.title, seller_name: current_seller.name_or_username),
        default_seo_description: nil,
      }
    end

    def seo_params
      params.permit(:seo_title, :seo_description).to_h.symbolize_keys
    end

    def page_errors(page)
      page.errors.to_hash.transform_values(&:first)
    end

    # Slug rules live on the model so the management UI and the API stay in
    # sync: parameterized title, "page" fallback, numbered on collision.
    def generate_slug(title)
      Page.generate_slug_for(current_seller, title)
    end

    # The profile rendered as the root of the page tree: first in the list
    # (named "Home" there), can't be deleted, serves at the storefront root.
    def profile_entry
      {
        username: current_seller.username.to_s,
        profile_url: current_seller.profile_url,
        custom_html: current_seller.custom_html.present?,
      }
    end
end
