# frozen_string_literal: true

# Design draft for first-class Pages (gumroad-private#1047).
#
# This controller renders the full Pages UX — a list of the seller's pages with
# the public profile pinned as the special "home" entry, plus an editor with a
# live preview — so the flow can be clicked through end to end and iterated on.
#
# DESIGN STUB: there is no real data layer behind this yet. Pages live in the
# session (seeded with sample content the first time the list is opened), so
# creating, editing, saving, and deleting all feel real within a browser
# session but nothing is persisted. The real implementation replaces the
# session store with a `pages` table (seller-scoped, slug + title + content)
# and routes saved content through the existing sanitizer pipeline.
class PagesController < Sellers::BaseController
  layout "inertia"

  SESSION_KEY = :design_draft_pages

  # Sample pages so the list and editor render with believable content on
  # first load instead of an empty state.
  SEED_PAGES = [
    {
      "slug" => "about",
      "title" => "About",
      "content" => "<h2>Hey, I'm glad you're here</h2><p>I make design resources for indie creators — icon sets, Figma templates, and the occasional deep-dive tutorial. Everything in the store is something I use in my own client work first.</p><p>If you're not sure where to start, the <strong>Starter Icon Pack</strong> is free.</p>",
      "custom_html" => false,
    },
    {
      "slug" => "licenses",
      "title" => "Licenses",
      "content" => "<h2>How you can use my work</h2><p>Every product includes a standard license for personal and client projects. You can:</p><ul><li>Use assets in unlimited personal and commercial projects</li><li>Modify and combine them with your own work</li></ul><p>You can't resell or redistribute the raw files. For team licenses, reach out through the contact page.</p>",
      "custom_html" => false,
    },
    {
      "slug" => "studio",
      "title" => "Studio",
      "content" => "<p>A page built by my agent with a fully custom layout.</p>",
      "custom_html" => true,
    },
  ].freeze

  def index
    authorize :page

    render inertia: "Pages/Index", props: {
      pages: stub_pages,
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

    title = params[:title].to_s.strip
    return redirect_to new_page_path, inertia: { errors: { title: "Title can't be blank" } } if title.blank?

    slug = title.parameterize
    slug = "#{slug}-#{stub_pages.size + 1}" if slug.blank? || stub_pages.any? { |p| p["slug"] == slug }
    pages = stub_pages + [{ "slug" => slug, "title" => title, "content" => params[:content].to_s, "custom_html" => false }]
    write_stub_pages(pages)

    redirect_to edit_page_path(slug), notice: "Page created!", status: :see_other
  end

  def edit
    authorize :page

    if params[:slug] == "profile"
      # The profile is the special root page: it renders the default storefront
      # template (product grid, follow form, tabs), with the details edited in
      # profile settings. Sellers keep it 100% customizable by replacing it with
      # fully custom HTML via their agent or the CLI, so the editor renders the
      # template view with that takeover path.
      render inertia: "Pages/Edit", props: {
        page: { slug: "profile", title: "Profile", content: "", custom_html: current_seller.custom_html.present? },
        is_profile: true,
        is_new: false,
        username: current_seller.username.to_s,
        profile_url: current_seller.profile_url,
      }
      return
    end

    page = stub_pages.find { |p| p["slug"] == params[:slug] }
    return redirect_to pages_path unless page

    render inertia: "Pages/Edit", props: {
      page:,
      is_profile: false,
      is_new: false,
      username: current_seller.username.to_s,
      profile_url: current_seller.profile_url,
    }
  end

  def update
    authorize :page

    pages = stub_pages
    page = pages.find { |p| p["slug"] == params[:slug] }
    return redirect_to pages_path unless page

    title = params[:title].to_s.strip
    return redirect_to edit_page_path(page["slug"]), inertia: { errors: { title: "Title can't be blank" } } if title.blank?

    page["title"] = title
    page["content"] = params[:content].to_s
    write_stub_pages(pages)

    redirect_to edit_page_path(page["slug"]), notice: "Changes saved!", status: :see_other
  end

  def destroy
    authorize :page

    write_stub_pages(stub_pages.reject { |p| p["slug"] == params[:slug] })
    redirect_to pages_path, notice: "Page deleted!", status: :see_other
  end

  private
    def stub_pages
      session[SESSION_KEY] ||= SEED_PAGES.map(&:dup)
    end

    def write_stub_pages(pages)
      session[SESSION_KEY] = pages
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
