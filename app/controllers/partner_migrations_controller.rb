# frozen_string_literal: true

# The page a creator reaches from a partner application's onboarding link.
#
# The link carries the code in `migration_code`, a filtered parameter, so request logs redact it.
# The first request moves the code into the session and redirects, so the code does not stay in the
# address bar, browser history, or the login page's `next` parameter.
class PartnerMigrationsController < ApplicationController
  SESSION_KEY = :partner_migration_code

  before_action :hide_layouts
  before_action :hide_from_search_results
  before_action :move_code_to_session, only: :show
  before_action :authenticate_user!, only: [:show, :create]
  before_action :load_migration, only: [:show, :create]

  def show
  end

  def create
    # The session holds the last link opened, which may differ from the page this form came from.
    if params[:partner_migration_id].to_s != @migration.id.to_s
      @error_message = "This page is out of date. Open the link from the application again."
      return render :show, status: :unprocessable_entity
    end

    @migration.claim!(current_user)
    session.delete(SESSION_KEY)
    @claimed = true
    render :show
  rescue PartnerMigration::ClaimError => e
    @error_message = e.message
    render :show, status: :unprocessable_entity
  end

  private
    def move_code_to_session
      return if params[:migration_code].blank?

      session[SESSION_KEY] = params[:migration_code].to_s
      redirect_to partner_migration_path
    end

    def load_migration
      @migration = PartnerMigration.find_by_code(session[SESSION_KEY])

      if impersonating?
        @error_message = "Stop impersonating before importing products."
      elsif @migration.nil? || !@migration.claimable_by?(current_user)
        @error_message = "This link is invalid or expired. Ask the application that sent you here for a new link."
      end
      render :show, status: :unprocessable_entity if @error_message.present? && action_name == "create"
    end

    def hide_layouts
      @hide_layouts = true
    end

    def hide_from_search_results
      headers["X-Robots-Tag"] = "noindex"
    end
end
