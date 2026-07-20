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

    resulting_html, marked_html, error = resulting_custom_html
    return render json: { success: false, error: } if error
    # A blank update is the real endpoint's "clear the page" — a valid change, not an error.
    return render_cleared_page_preview if resulting_html.nil?

    sanitized = Ai::PageSanitizer.sanitize_with_report(resulting_html).html.presence
    # The apply path stores `result.html.presence`, so a page that sanitizes down to nothing also
    # unpublishes — preview that outcome the same way instead of blocking the proposal.
    return render_cleared_page_preview if sanitized.nil?

    display_html, scroll_to_change = marked_preview_html(sanitized, marked_html)
    document = profile_custom_html_document(
      Pages::Interpolator.interpolate_profile(display_html, profile: current_seller),
      data_json: ERB::Util.json_escape(Pages::ProfileData.build(current_seller).to_json),
      meta_csp: true,
      scroll_to_change:,
    )
    render json: { success: true, html: document }
  end

  private
    def authorize_store_agent
      authorize current_seller, :use_store_agent?
    end

    # The preview for a proposal that unpublishes the custom page (a blank update, or an edit
    # whose result sanitizes down to nothing). Clearing reverts the profile to the default
    # storefront, so the preview shows that — the same render GET /v2/user/custom_html hands
    # agents as a starting point — instead of treating a valid "remove the page" proposal as
    # an unpreviewable error (which would leave its Confirm button permanently disabled).
    def render_cleared_page_preview
      render json: { success: true, html: Pages::DefaultProfileDocument.render(current_seller) }
    end

    # [resulting_html, marked_html, error]: the page as it would read after the proposed change
    # (or an error explaining why it can't be computed), plus — for edits — a variant with
    # PREVIEW_CHANGED_MARKER spliced in front of the replacement so the preview document can
    # scroll to where the page changed. All-nil means the proposal clears the page (a valid
    # outcome the caller previews as the default storefront). Mirrors the matching rules of the
    # real edit endpoint so the preview and the eventual apply always agree on what the change
    # does.
    def resulting_custom_html
      case params[:endpoint].to_s
      when "update_user_custom_html"
        # Mirror the real endpoint's parameter validation exactly: it rejects a request without a
        # custom_html key and a non-nil non-string value. If the preview were laxer here, a
        # malformed staged proposal would render fine and enable Confirm, then fail on apply.
        return [nil, nil, "The proposed update is missing its custom_html value."] unless params.key?(:custom_html)

        custom_html = params[:custom_html]
        if !custom_html.nil? && !custom_html.is_a?(String)
          return [nil, nil, "custom_html must be a string."]
        end

        # Blank clears the page on the real endpoint (Api::V2::UsersController#update_custom_html
        # normalizes blank to nil), so it's a previewable outcome — signalled as a nil result, not
        # an error, and the caller previews the cleared state instead.
        return [nil, nil, nil] if custom_html.blank?

        return [nil, nil, custom_html_length_error(custom_html)] if custom_html_length_error(custom_html)

        # A whole-page update has no single "changed area" to point at, so no marked variant.
        [custom_html, nil, nil]
      when "edit_user_custom_html"
        # Same principle as the update branch: validate find/replace with the exact rules the real
        # edit endpoint applies (find must be a non-empty string, replace must be a string), and
        # in the same order, so a proposal that would fail on apply also fails to preview.
        find = params[:find]
        unless find.is_a?(String) && find.present?
          return [nil, nil, "The proposed edit is missing the snippet to replace."]
        end

        replace = params[:replace]
        unless replace.is_a?(String)
          return [nil, nil, "The proposed edit is missing the replacement text."]
        end

        current = current_seller.custom_html
        return [nil, nil, "There is no custom HTML page to edit."] if current.blank?

        occurrences = current.scan(find).size
        return [nil, nil, "The snippet to replace no longer appears in the current page."] if occurrences.zero?
        return [nil, nil, "The snippet to replace matches #{occurrences} places in the current page."] if occurrences > 1

        # Block form so the replacement is inserted literally — the two-argument form of
        # String#sub treats backslash sequences (\0, \1, \\) specially, which would corrupt HTML
        # that legitimately contains backslashes. Matches the real edit endpoint.
        edited = current.sub(find) { replace }
        return [nil, nil, custom_html_length_error(edited)] if custom_html_length_error(edited)

        # If the page (or the replacement) somehow already contains the marker text, the scroll
        # script could land on the wrong occurrence — skip marking and let the preview open at
        # the top rather than point somewhere misleading.
        marked =
          if edited.include?(PREVIEW_CHANGED_MARKER_TEXT)
            nil
          else
            current.sub(find) { PREVIEW_CHANGED_MARKER + replace }
          end
        [edited, marked, nil]
      else
        [nil, nil, "This change doesn't have a page preview."]
      end
    end

    # [html_to_render, scroll_to_change]. Serves the marker-carrying variant only when — marker
    # comments aside — it sanitizes to exactly the page the seller would publish. An edit can
    # match mid-text or even inside an attribute value, where the spliced comment wouldn't land
    # as a standalone comment node; in that case the marked variant is NOT the real result, so
    # the preview falls back to the unmarked page (opening at the top) rather than showing
    # something confirming wouldn't produce.
    def marked_preview_html(sanitized, marked_html)
      return [sanitized, false] if marked_html.nil?

      sanitized_marked = Ai::PageSanitizer.sanitize_with_report(marked_html).html.to_s
      # Both sides run through the same strip-and-reserialize so serialization quirks can't
      # produce a spurious mismatch — for the unmarked page stripping is a semantic no-op.
      return [sanitized, false] unless strip_preview_markers(sanitized_marked) == strip_preview_markers(sanitized)

      [sanitized_marked, true]
    end

    def strip_preview_markers(html)
      fragment = Loofah.fragment(html)
      fragment.traverse { |node| node.remove if node.comment? && node.content == PREVIEW_CHANGED_MARKER_TEXT }
      fragment.to_html
    end

    def custom_html_length_error(html)
      return if html.length <= Page::MAX_CUSTOM_HTML_LENGTH

      "The edited page would be too long (maximum is #{Page::MAX_CUSTOM_HTML_LENGTH} characters)."
    end
end
