# frozen_string_literal: true

# First-class Pages (gumroad-private#1047): the seller-facing management UI.
#
# The list shows the seller's public profile pinned as the special "home" entry
# plus every slugged page; the editor is a title + rich text form with a live
# preview. Pages built as full custom HTML by an agent/CLI show a preview and
# the agent path instead of the rich text editor — there is no lossy
# HTML → rich text conversion.
class PagesController < Sellers::BaseController
  layout "inertia"

  before_action :set_page, only: [:edit, :update, :destroy]

  def index
    authorize :page

    render inertia: "Pages/Index", props: {
      pages: current_seller.pages.map { page_props(_1) },
      profile: profile_entry,
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
      render inertia: "Pages/Edit", props: {
        page: { slug: "profile", title: "Profile", content: "", custom_html: current_seller.custom_html.present? },
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

    # Slugs come from the title; on collision (or an all-symbols title that
    # parameterizes to nothing) fall back to a numbered variant.
    def generate_slug(title)
      base = title.parameterize
      base = "page" if base.blank?
      return base unless slug_taken?(base)

      (2..).each do |n|
        candidate = "#{base}-#{n}"
        return candidate unless slug_taken?(candidate)
      end
    end

    def slug_taken?(slug)
      Page::RESERVED_SLUGS.include?(slug) || current_seller.pages.exists?(slug:)
    end

    # The profile rendered as the root of the page tree: first in the list,
    # can't be deleted, serves at the storefront root.
    def profile_entry
      {
        title: current_seller.name.presence || current_seller.username.to_s,
        username: current_seller.username.to_s,
        profile_url: current_seller.profile_url,
        custom_html: current_seller.custom_html.present?,
      }
    end
end
