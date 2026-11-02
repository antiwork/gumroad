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
  skip_before_action :require_account_email, only: [:show, :switch_account]
  before_action :load_migration, only: [:show, :create]

  def show
    return unless @migration&.user_id == current_user.id

    reset_current_seller
    redirect_to products_path
  end

  def create
    if stale_form?
      @error_message = PartnerMigration::OUT_OF_DATE_MESSAGE
      return render :show, status: :unprocessable_entity
    end

    @migration.claim!(current_user, expected_code_digest: params[:partner_migration_code_digest])
    session.delete(SESSION_KEY)
    redirect_to_products(@migration)
  rescue PartnerMigration::ClaimError => e
    @error_message = e.message
    render :show, status: :unprocessable_entity
  end

  def switch_account
    code = session[SESSION_KEY]
    sign_out current_user
    session[SESSION_KEY] = code
    redirect_to login_path(next: partner_migration_path), status: :see_other
  end

  private
    # The session holds the last link opened, which may differ from the page that the form came from.
    def stale_form?
      params[:partner_migration_id] != @migration.public_id || params[:partner_migration_code_digest] != @migration.code_digest
    end

    # The drafts appear on the products page as they import. The notice follows the import's status.
    def redirect_to_products(migration)
      count = migration.products.size
      products = count == 1 ? "product" : "#{count} products"
      app_name = migration.oauth_application.name
      notice = case migration.status
               when PartnerMigration::STATUS_COMPLETED
                 "Your #{products} from #{app_name} #{count == 1 ? "is" : "are"} here as drafts."
               when PartnerMigration::STATUS_FAILED
                 "Some products from #{app_name} did not import. The others are here as drafts."
               else
                 "We're importing your #{products} from #{app_name}. #{count == 1 ? "It appears" : "They appear"} here as drafts."
      end
      # The import belongs to the logged-in account, so the products page must not show a seller that
      # the account switcher selected.
      reset_current_seller
      redirect_to products_path, notice:, status: :see_other
    end

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

    def hide_layouts
      @hide_layouts = true
    end

    def hide_from_search_results
      headers["X-Robots-Tag"] = "noindex"
    end
end
