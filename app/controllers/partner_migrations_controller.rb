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
  before_action :authenticate_user!
  include RequireAccountEmail
  skip_before_action :require_account_email, only: [:show, :status, :switch_account]
  before_action :load_migration, only: [:show, :create]
  before_action :load_owned_migration, only: [:status, :retry_import]

  def show
    redirect_to partner_migration_status_path(@migration.public_id) if @migration&.user_id == current_user.id
  end

  def create
    # The session holds the last link opened, which may differ from the page this form came from.
    if params[:partner_migration_id] != @migration.public_id || params[:partner_migration_code_digest] != @migration.code_digest
      @error_message = "This page is out of date. Open the link from the application again."
      return render :show, status: :unprocessable_entity
    end

    @migration.claim!(current_user, expected_code_digest: params[:partner_migration_code_digest])
    session.delete(SESSION_KEY)
    redirect_to partner_migration_status_path(@migration.public_id), status: :see_other
  rescue PartnerMigration::ClaimError => e
    @error_message = e.message
    render :show, status: :unprocessable_entity
  end

  def status
    response.headers["Refresh"] = "5" if @migration.status == PartnerMigration::STATUS_CLAIMED
    @products = current_user.links.by_external_ids(@migration.results.to_h.values.filter_map { _1["product_id"] }).index_by(&:external_id)
  end

  def retry_import
    @migration.retry!(current_user)
    redirect_to partner_migration_status_path(@migration.public_id), status: :see_other
  rescue PartnerMigration::ClaimError => e
    redirect_to partner_migration_status_path(@migration.public_id), warning: e.message, status: :see_other
  end

  def switch_account
    code = session[SESSION_KEY]
    sign_out current_user
    session[SESSION_KEY] = code
    redirect_to login_path(next: partner_migration_path), status: :see_other
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
      elsif @migration.nil? || (!@migration.claimable_by?(current_user) && @migration.user_id != current_user.id)
        @error_message = "This link is invalid or expired. Ask the application that sent you here for a new link."
      end
      render :show, status: :unprocessable_entity if @error_message.present? && action_name == "create"
    end

    def load_owned_migration
      @migration = PartnerMigration.find_by_public_id(params[:id])
      e404 unless @migration&.user_id == current_user.id && !impersonating?
    end

    def hide_layouts
      @hide_layouts = true
    end

    def hide_from_search_results
      headers["X-Robots-Tag"] = "noindex"
    end
end
