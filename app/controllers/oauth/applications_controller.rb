# frozen_string_literal: true

class Oauth::ApplicationsController < Doorkeeper::ApplicationsController
  RESERVED_AGENT_APP_NAME_ERROR = "That application name is reserved."

  protect_from_forgery

  include CsrfTokenInjector

  before_action :authenticate_user!
  before_action :set_application_params, only: %i[create update]
  before_action :set_application, only: %i[edit update destroy]
  after_action :verify_authorized, except: %i[index new show]

  layout "inertia"

  def index
    redirect_to settings_advanced_path
  end

  def new
    redirect_to settings_advanced_path
  end

  def create
    @application = OauthApplication.new
    authorize([:settings, :authorized_applications, @application])
    return reject_reserved_agent_application_name(settings_advanced_path) if reserved_agent_application_name?

    @application.name = @application_params[:name]
    @application.redirect_uri = @application_params[:redirect_uri]
    @application.owner = current_seller
    @application.owner_type = "User"

    if params[:signed_blob_id].present?
      @application.file.attach(params[:signed_blob_id])
    elsif params.has_key?(:signed_blob_id) && @application.file.attached?
      @application.file.purge
    end

    if @application.save
      redirect_to edit_oauth_application_path(@application.external_id), notice: "Application created."
    else
      redirect_to settings_advanced_path, alert: @application.errors.full_messages.to_sentence, inertia: { errors: { base: @application.errors.full_messages } }
    end
  end

  def show
    redirect_to edit_oauth_application_path(params[:id])
  end

  def edit
    set_meta_tag(title: "Update application")
    authorize([:settings, :authorized_applications, @application])

    settings_presenter = SettingsPresenter.new(pundit_user:)
    render inertia: "Oauth/Applications/Edit",
           props: settings_presenter.application_props(@application)
  end

  def update
    authorize([:settings, :authorized_applications, @application])
    return reject_reserved_agent_application_name(edit_oauth_application_path(@application.external_id)) if reserved_agent_application_name?

    @application.name = @application_params[:name] if @application_params[:name].present?
    @application.redirect_uri = @application_params[:redirect_uri] if @application_params[:redirect_uri].present?
    if params[:signed_blob_id].present?
      @application.file.attach(params[:signed_blob_id])
    elsif params.has_key?(:signed_blob_id) && @application.file.attached?
      @application.file.purge
    end

    if @application.save
      redirect_to edit_oauth_application_path(@application.external_id), notice: "Application updated."
    else
      redirect_to edit_oauth_application_path(@application.external_id),
                  alert: @application.errors.full_messages.to_sentence,
                  inertia: { errors: { base: @application.errors.full_messages } }
    end
  end

  def destroy
    authorize([:settings, :authorized_applications, @application])

    @application.mark_deleted!

    redirect_to settings_advanced_path, notice: "Application deleted."
  end

  private
    def set_application_params
      @application_params = if params[:oauth_application].respond_to?(:slice)
        params[:oauth_application].slice(:name, :redirect_uri, :affiliate_percent)
      else
        {}
      end
    end

    def set_application
      @application = current_seller.oauth_applications.alive.find_by_external_id(params[:id])
      return if @application.present?

      respond_to do |format|
        format.json do
          render json: { success: false,
                         message: "Application not found or you don't have the permissions to modify it.",
                         redirect_location: oauth_applications_url }
        end
        format.html do
          flash[:alert] = "Application not found or you don't have the permissions to modify it."
          redirect_to oauth_applications_url
        end
      end
    end

    # Ask the database, not Ruby. The adoption fingerprint matches `name` under utf8mb4_unicode_ci,
    # which folds full-width forms and ignores zero-width characters — so a name Ruby's casecmp?
    # considers different can still satisfy that fingerprint. Comparing with the same collation is
    # what makes this check and the fingerprint agree.
    def reserved_agent_application_name?
      name = @application_params[:name].to_s.strip
      return false if name.blank?

      OauthApplication.connection.select_value(
        OauthApplication.sanitize_sql_array(
          ["SELECT ? = ? COLLATE utf8mb4_unicode_ci", name, Ai::StoreAgentApiClient::AGENT_APP_NAME]
        )
      ) == 1
    end

    def reject_reserved_agent_application_name(path)
      redirect_to path,
                  alert: RESERVED_AGENT_APP_NAME_ERROR,
                  inertia: { errors: { base: [RESERVED_AGENT_APP_NAME_ERROR] } }
    end
end
