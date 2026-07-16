# frozen_string_literal: true

# Renders a visual preview of a custom-HTML change the store agent has proposed but the seller
# hasn't confirmed yet. The confirmation card for edit_user_custom_html / update_user_custom_html
# proposals otherwise shows only the raw find/replace markup — which sellers read as the agent
# glitching rather than as a staged page edit. This endpoint computes the page as it WOULD look
# after the change and returns the same sandboxed document the live /landing/embed endpoint
# serves, so the card can render a real preview inside an opaque-origin iframe.
#
# Nothing is written here: the edit is spliced into an in-memory copy of the current page under
# the same exactly-once find-match rule the real edit endpoint enforces
# (Api::V2::UsersController#edit_custom_html), and the result runs through the same
# Ai::PageSanitizer before rendering — so what the preview shows is what confirming would publish.
class Api::Internal::AgentCustomHtmlPreviewsController < Api::Internal::BaseController
  include RendersCustomHtmlPages

  before_action :authenticate_user!
  before_action :authorize_store_agent
  after_action :verify_authorized

  # POST /internal/agent/custom_html_preview
  # params: { endpoint: "edit_user_custom_html" | "update_user_custom_html",
  #           find:, replace:   (edit)  —or—  custom_html: (update) }
  # Renders { success: true, html: <full sandboxed document> } or { success: false, error: }.
  # Errors render as 200s with success: false — a proposal whose preview can't be computed (say,
  # the page changed under it) is an expected state the card shows inline, not a request failure.
  def create
    unless Feature.active?(:custom_html_pages, current_seller)
      return render json: { success: false, error: "Custom HTML pages are not enabled on this account." }
    end

    resulting_html, error = resulting_custom_html
    return render json: { success: false, error: } if error

    sanitized = Ai::PageSanitizer.sanitize_with_report(resulting_html).html.presence
    if sanitized.nil?
      return render json: { success: false, error: "This change would leave the page empty, so there is nothing to preview." }
    end

    document = profile_custom_html_document(
      Pages::Interpolator.interpolate_profile(sanitized, profile: current_seller),
      data_json: ERB::Util.json_escape(Pages::ProfileData.build(current_seller).to_json),
      meta_csp: true,
    )
    render json: { success: true, html: document }
  end

  private
    def authorize_store_agent
      authorize current_seller, :use_store_agent?
    end

    # [resulting_html, error]: the page as it would read after the proposed change, or an error
    # explaining why it can't be computed. Mirrors the matching rules of the real edit endpoint so
    # the preview and the eventual apply always agree on what the change does.
    def resulting_custom_html
      case params[:endpoint].to_s
      when "update_user_custom_html"
        custom_html = params[:custom_html]
        unless custom_html.is_a?(String) && custom_html.present?
          return [nil, "This change removes the custom page, so there is nothing to preview."]
        end
        return [nil, custom_html_length_error(custom_html)] if custom_html_length_error(custom_html)

        [custom_html, nil]
      when "edit_user_custom_html"
        current = current_seller.custom_html
        return [nil, "There is no custom HTML page to edit."] if current.blank?

        find = params[:find].to_s
        return [nil, "The proposed edit is missing the snippet to replace."] if find.empty?

        occurrences = current.scan(find).size
        return [nil, "The snippet to replace no longer appears in the current page."] if occurrences.zero?
        return [nil, "The snippet to replace matches #{occurrences} places in the current page."] if occurrences > 1

        # Block form so the replacement is inserted literally — the two-argument form of
        # String#sub treats backslash sequences (\0, \1, \\) specially, which would corrupt HTML
        # that legitimately contains backslashes. Matches the real edit endpoint.
        edited = current.sub(find) { params[:replace].to_s }
        return [nil, custom_html_length_error(edited)] if custom_html_length_error(edited)

        [edited, nil]
      else
        [nil, "This change doesn't have a page preview."]
      end
    end

    def custom_html_length_error(html)
      return if html.length <= Page::MAX_CUSTOM_HTML_LENGTH

      "The edited page would be too long (maximum is #{Page::MAX_CUSTOM_HTML_LENGTH} characters)."
    end
end
