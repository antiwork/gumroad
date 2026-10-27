# frozen_string_literal: true

# The page a creator reaches from a partner application's onboarding link.
#
# The link carries the code in `migration_code`, a filtered parameter, so request logs redact it.
# The first request moves the code into the session and redirects, so the code does not stay in the
# address bar, browser history, or the login page's `next` parameter.
class PartnerMigrationsController < ApplicationController
  SESSION_KEY = :partner_migration_code
  SETUP_SESSION_KEY = :partner_migration_account_setup_token
  ACCOUNT_SETUP_ACTIONS = [:create_account, :resend_setup, :setup, :complete_setup].freeze

  before_action :hide_layouts
  before_action :hide_from_search_results
  before_action :move_code_to_session, only: :show
  before_action :show_new_account, only: :show
  before_action :move_setup_token_to_session, only: :setup
  before_action :authenticate_user!, except: ACCOUNT_SETUP_ACTIONS
  include RequireAccountEmail
  skip_before_action :require_account_email, only: [:show, :switch_account, *ACCOUNT_SETUP_ACTIONS]
  before_action :load_migration, only: [:show, :create]

  def show
    redirect_to products_path if @migration&.user_id == current_user.id
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

  # A POST, so a link preview or a server that fetches the link cannot create an account.
  def create_account
    @migration = PartnerMigration.find_by_code(session[SESSION_KEY])
    if !user_signed_in? && @migration&.account_creatable?
      if stale_form?
        @error_message = PartnerMigration::OUT_OF_DATE_MESSAGE
        return render :create_account, status: :unprocessable_entity
      end

      @error_message = @migration.create_account_and_claim!(ip: request.remote_ip, expected_code_digest: params[:partner_migration_code_digest])
      return render :create_account, status: :unprocessable_entity if @error_message

      create_user_event("signup", user_id: @migration.user_id) if @migration.account_created
    end
    redirect_to partner_migration_path, status: :see_other
  end

  def resend_setup
    migration = PartnerMigration.find_by_code(session[SESSION_KEY])
    if migration&.account_setup_pending?
      flash[:notice] = {
        sent: "We sent the email again.",
        limit: "We cannot send more emails. Check your spam folder, or contact Gumroad support.",
        too_soon: "Wait a minute, then ask for another email.",
        expired: nil,
      }.fetch(migration.resend_account_setup!)
    end
    redirect_to partner_migration_path, status: :see_other
  end

  def setup
    @migration = PartnerMigration.find_by_account_setup_token(session[SETUP_SESSION_KEY])
  end

  def complete_setup
    @migration = PartnerMigration.find_by_account_setup_token(session[SETUP_SESSION_KEY])
    return render :setup, status: :unprocessable_entity if @migration.nil?

    # The session holds the last setup link opened, which may differ from the page that the form came from.
    if params[:partner_migration_id] != @migration.public_id || params[:account_setup_token_digest] != @migration.account_setup_token_digest
      @error_message = PartnerMigration::OUT_OF_DATE_MESSAGE
      return render :setup, status: :unprocessable_entity
    end

    unless params[:terms_accepted] == "1"
      @error_message = "Accept the Terms of Use to continue."
      return render :setup, status: :unprocessable_entity
    end

    @migration.complete_account_setup!(password: params[:password].to_s, ip: request.remote_ip, expected_token_digest: params[:account_setup_token_digest])
    session.delete(SETUP_SESSION_KEY)
    sign_in_new_seller(@migration.user)
    redirect_to_products(@migration)
  rescue ActiveRecord::RecordInvalid => e
    @error_message = e.record.errors.full_messages.first
    render :setup, status: :unprocessable_entity
  rescue PartnerMigration::AccountSetupError => e
    @error_message = e.message
    render :setup, status: :unprocessable_entity
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

    # The drafts appear on the products page as they import. After the password setup, the import has
    # often finished, so the notice follows its status.
    def redirect_to_products(migration)
      count = migration.products.size
      products = count == 1 ? "product" : "#{count} products"
      app_name = migration.oauth_application.name
      notice = case migration.status
               when PartnerMigration::STATUS_COMPLETED
                 "Your #{products} from #{app_name} #{count == 1 ? "is" : "are"} here as drafts."
               when PartnerMigration::STATUS_FAILED
                 "Some products from #{app_name} did not import. We try them again when #{app_name} sends them again."
               else
                 "We're importing your #{products} from #{app_name}. #{count == 1 ? "It appears" : "They appear"} here as drafts."
      end
      redirect_to products_path, notice:, status: :see_other
    end

    def move_code_to_session
      return if params[:migration_code].blank?

      session[SESSION_KEY] = params[:migration_code].to_s
      redirect_to partner_migration_path
    end

    # A logged-out seller whose export names an email without a Gumroad account can create one here,
    # so they do not sign up. Until they set a password, opening the link again shows the email step.
    def show_new_account
      return if user_signed_in?

      @migration = PartnerMigration.find_by_code(session[SESSION_KEY])
      if @migration&.account_creatable?
        render :create_account
      elsif @migration&.account_setup_pending?
        render :check_email
      end
    end

    # Like signup, the first sign-in of a new account skips two-factor authentication: the emailed link
    # has just proven the address that a two-factor code would go to.
    def sign_in_new_seller(user)
      sign_in user
      reset_two_factor_auth_login_session
      merge_guest_cart_with_user_cart
      refresh_passkey_setup_prompt(user)
      remember_two_factor_auth
    end

    # The emailed link carries the token in a filtered parameter. Like the onboarding code, it moves
    # into the session, so it does not stay in the address bar or browser history. Only a token for a
    # pending setup is kept, so a link cannot replace a valid token with one that does nothing.
    def move_setup_token_to_session
      return if params[:account_setup_token].blank?

      token = params[:account_setup_token].to_s
      session[SETUP_SESSION_KEY] = token if PartnerMigration.find_by_account_setup_token(token)
      redirect_to partner_migration_account_setup_path
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
