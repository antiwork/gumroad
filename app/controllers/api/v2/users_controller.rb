# frozen_string_literal: true

class Api::V2::UsersController < Api::V2::BaseController
  before_action -> { doorkeeper_authorize!(*Doorkeeper.configuration.public_api_read_scopes.concat([:view_public])) }, only: [:show, :ifttt_sale_trigger, :custom_html]
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
  def custom_html
    user = current_resource_owner
    render_response(true, custom_html: user.custom_html, has_landing_page: user.has_custom_landing_page?, profile_url: profile_url_for(user))
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

    previous_custom_html = nil
    sanitization_report = nil
    begin
      ActiveRecord::Base.transaction do
        # Lock the user row so concurrent custom_html PUTs serialize their
        # build_page calls — otherwise they race against the pages unique index.
        # lock! reloads the row, swapping in a fresh association cache so the
        # previous_custom_html read reflects a concurrent writer's committed page.
        user.lock!
        previous_custom_html = user.custom_html
        if params[:custom_html].blank?
          user.custom_html = nil
          sanitization_report = Ai::PageSanitizer.empty_report
        else
          result = Ai::PageSanitizer.sanitize_with_report(params[:custom_html])
          user.custom_html = result.html.presence
          sanitization_report = result.report
        end
        user.save!
      end
    rescue ActiveRecord::RecordInvalid => e
      return error_with_object(:user, e.record)
    end

    render_response(true, custom_html: user.custom_html, previous_custom_html:, sanitization_report:, profile_url: profile_url_for(user))
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

    previous_custom_html = nil
    sanitization_report = nil
    edit_error = nil
    begin
      ActiveRecord::Base.transaction do
        # Same row lock as update_custom_html: serializes concurrent writers and reloads the
        # association cache, so the find/replace below splices against the latest committed page
        # instead of a stale in-memory copy.
        user.lock!
        previous_custom_html = user.custom_html

        if previous_custom_html.blank?
          edit_error = "There is no custom HTML page to edit. Publish one first with the full custom_html update."
          raise ActiveRecord::Rollback
        end

        # `find` must match exactly once so the edit is unambiguous. Zero matches means the caller
        # is working from stale HTML; multiple matches means the snippet needs more surrounding
        # context. Both errors say so explicitly, so the agent can correct itself in the same turn.
        occurrences = previous_custom_html.scan(find).size
        if occurrences.zero?
          edit_error = "find does not appear in the current custom HTML. Re-read the page and copy the snippet exactly, including whitespace."
          raise ActiveRecord::Rollback
        elsif occurrences > 1
          edit_error = "find matches #{occurrences} places in the current custom HTML. Include more surrounding context so it matches exactly once."
          raise ActiveRecord::Rollback
        end

        # Block form so the replacement is inserted literally — the two-argument form of String#sub
        # treats backslash sequences (\0, \1, \\) in the replacement specially, which would corrupt
        # HTML that legitimately contains backslashes.
        edited = previous_custom_html.sub(find) { replace }

        if edited.length > Page::MAX_CUSTOM_HTML_LENGTH
          edit_error = "The edited custom_html would be too long (maximum is #{Page::MAX_CUSTOM_HTML_LENGTH} characters)."
          raise ActiveRecord::Rollback
        end

        # Re-sanitize the whole spliced result, not just the inserted snippet: the replacement can
        # change how surrounding markup parses (for example by opening a tag the snippet closes), so
        # only the full document is safe to check. Matches update_custom_html's blank-to-nil
        # normalization so an edit that empties the page unpublishes it the same way.
        result = Ai::PageSanitizer.sanitize_with_report(edited)
        user.custom_html = result.html.presence
        sanitization_report = result.report
        user.save!
      end
    rescue ActiveRecord::RecordInvalid => e
      return error_with_object(:user, e.record)
    end

    return render_response(false, message: edit_error) if edit_error

    render_response(true, custom_html: user.custom_html, previous_custom_html:, sanitization_report:, profile_url: profile_url_for(user))
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
    candidate_page = Page.new(pageable: current_resource_owner, custom_html: sanitized)
    candidate_page.validate
    errors = candidate_page.errors.where(:custom_html)

    if errors.any?
      render_response(false, message: errors.map(&:full_message).to_sentence, sanitization_report: result.report)
    else
      render_response(true, custom_html: sanitized, sanitization_report: result.report)
    end
  end

  def ifttt_status
    render json: { status: "success" }
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
