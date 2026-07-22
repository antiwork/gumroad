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

  layout "inertia"

  before_action :set_page, only: [:edit, :update, :destroy, :preview]

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
      page: { slug: nil, title: "", content: "", custom_html: false },
      is_profile: false,
      is_new: true,
      username: current_seller.username.to_s,
      profile_url: current_seller.profile_url,
    }
  end

  def create
    authorize :page

    page = current_seller.pages.build(title: params[:title].to_s.strip, content: params[:content].to_s)
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
        page: { slug: "profile", title: "Home", content: "", custom_html: current_seller.custom_html.present? },
        is_profile: true,
        is_new: false,
        username: current_seller.username.to_s,
        profile_url: current_seller.profile_url,
      }
      return
    end

    render inertia: "Pages/Edit", props: {
      page: page_props(@page),
      is_profile: false,
      is_new: false,
      username: current_seller.username.to_s,
      profile_url: current_seller.profile_url,
    }
  end

  def update
    authorize :page

    if @profile_page
      # The only edit the profile entry supports here is removing a custom HTML
      # takeover, which restores the default storefront template. Everything
      # else about the profile is edited in profile settings.
      if params[:remove_custom_html]
        current_seller.custom_html = nil
        current_seller.save!
        return redirect_to edit_page_path("profile"), notice: "Custom page removed — your profile is back on the default template.", status: :see_other
      end
      return redirect_to pages_path
    end

    # A custom HTML page is authored by the seller's agent/CLI; the in-app
    # editor never writes over it (the UI doesn't offer to, this is the
    # server-side backstop).
    return redirect_to edit_page_path(@page.slug) if @page.custom_html.present?

    if @page.update(title: params[:title].to_s.strip, content: params[:content].to_s)
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
    interpolated = Pages::Interpolator.interpolate_profile(custom_html, profile: current_seller)
    render html: <<~HTML.html_safe, layout: false
      <!doctype html>
      <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          #{SANDBOX_COMPAT_SCRIPT}
          #{self.class.pages_tailwind_head}
        </head>
        <body>
          #{interpolated}
          <!-- The editor preview has no trusted wrapper listening, so a follow
               can't complete here — but without the bridge a data-gumroad-follow
               form would native-submit and navigate the preview frame away,
               which reads as "the form is broken" while iterating. -->
          #{FOLLOW_BRIDGE_SCRIPT}
        </body>
      </html>
    HTML
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
      }
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
