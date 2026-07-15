# frozen_string_literal: true

# API surface for first-class Pages (gumroad-private#1047): the seller's
# slugged storefront pages, addressed by slug. This is what the `gumroad pages`
# CLI commands and store agents drive.
#
# A page carries either rich text `content` (what the in-app editor writes) or
# full `custom_html` (an agent/CLI-built takeover) — sending one clears the
# other, matching the either/or the management UI enforces. The profile root
# page is NOT addressable here; it keeps its dedicated /user/custom_html
# endpoints.
class Api::V2::PagesController < Api::V2::BaseController
  before_action -> { doorkeeper_authorize!(*Doorkeeper.configuration.public_api_read_scopes.concat([:view_public])) }, only: [:index, :show]
  before_action(only: [:create, :update, :destroy]) { doorkeeper_authorize! :edit_profile }
  # The base controller adds the broad legacy `account` scope as a fallback to every
  # doorkeeper_authorize! call. Writes to storefront pages are a narrower boundary, so
  # additionally require the edit_profile scope itself (same pattern as MediaController).
  before_action(only: [:create, :update, :destroy]) { require_oauth_scope! :edit_profile }
  before_action :ensure_confirmed_user, only: [:create, :update, :destroy]
  before_action :set_page, only: [:show, :update, :destroy]

  def index
    success_with_object(:pages, current_resource_owner.pages.map { page_json(_1) })
  end

  def show
    render_response(true, page: page_json(@page), rendered_html: rendered_html_for(@page))
  end

  def create
    unless params[:title].is_a?(String) && params[:title].strip.present?
      return render_response(false, message: "title is required.")
    end
    if (content_error = validate_content_params)
      return render_response(false, message: content_error)
    end

    page = current_resource_owner.pages.build(title: params[:title].strip)
    page.slug = requested_slug || generate_slug(page.title)
    assign_content(page)

    if page.save
      render_response(true, page: page_json(page))
    else
      error_with_object(:page, page)
    end
  end

  def update
    if (content_error = validate_content_params)
      return render_response(false, message: content_error)
    end

    @page.title = params[:title].strip if params[:title].is_a?(String) && params[:title].strip.present?
    assign_content(@page)

    if @page.save
      render_response(true, page: page_json(@page))
    else
      error_with_object(:page, @page)
    end
  end

  def destroy
    @page.destroy!
    render_response(true, message: "The page was deleted successfully.")
  end

  private
    def set_page
      @page = current_resource_owner.pages.find_by(slug: params[:id])
      render_response(false, message: "The page was not found.") unless @page
    end

    def ensure_confirmed_user
      unless current_resource_owner.confirmed?
        render_response(false, message: "You have to confirm your email address before you can do that.")
      end
    end

    # Exactly one content representation may be written per request: rich text
    # `content` or full `custom_html`. Custom HTML additionally needs the
    # custom_html_pages feature, same as the profile takeover endpoints.
    def validate_content_params
      if params.key?(:content) && params.key?(:custom_html)
        return "Send either content or custom_html, not both."
      end
      if params.key?(:content) && !params[:content].nil? && !params[:content].is_a?(String)
        return "content must be a string."
      end
      if params.key?(:custom_html)
        return "custom_html must be a string." if !params[:custom_html].nil? && !params[:custom_html].is_a?(String)
        unless Feature.active?(:custom_html_pages, current_resource_owner)
          return "You do not have access to custom HTML pages."
        end
        if params[:custom_html].to_s.length > Page::MAX_CUSTOM_HTML_LENGTH
          return "custom_html is too long (maximum is #{Page::MAX_CUSTOM_HTML_LENGTH} characters)."
        end
      end
      nil
    end

    # Writing one representation clears the other so a page is never both a
    # rich text page and a custom HTML takeover at once.
    def assign_content(page)
      if params.key?(:custom_html)
        page.custom_html = params[:custom_html].presence
        # Clear the other representation even when the new value is blank —
        # sending an empty custom_html means "this is now an (empty) custom
        # HTML page", so any previous rich text must stop being served.
        page.content = nil
      elsif params.key?(:content)
        page.content = params[:content].presence
        page.custom_html = nil
      end
    end

    def requested_slug
      params[:slug].presence if params[:slug].is_a?(String)
    end

    # Slug rules live on the model so the API and the management UI stay in
    # sync: parameterized title, "page" fallback, numbered on collision.
    def generate_slug(title)
      Page.generate_slug_for(current_resource_owner, title)
    end

    def page_json(page)
      user = current_resource_owner
      url = user.username.present? ? "#{user.subdomain_with_protocol}/#{page.slug}" : nil
      {
        slug: page.slug,
        title: page.title.to_s,
        content: page.content,
        custom_html: page.custom_html,
        url:,
        created_at: page.created_at,
        updated_at: page.updated_at,
      }
    end

    # The eject path: a faithful standalone-HTML render of the page as it
    # serves publicly today. When an agent takes over a rich text page with
    # custom HTML, it starts from this instead of reverse-engineering the
    # public layout from raw rich text. Custom HTML pages return the stored
    # HTML itself — that already IS the document.
    def rendered_html_for(page)
      return page.custom_html if page.custom_html.present?

      Pages::RichTextDocument.render(page:, seller_name: current_resource_owner.name_or_username).to_str
    end
end
