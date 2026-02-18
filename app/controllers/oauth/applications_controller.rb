# frozen_string_literal: true

class Oauth::ApplicationsController < Doorkeeper::ApplicationsController
  protect_from_forgery

  include CsrfTokenInjector
  include Impersonate

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

    @application.name = @application_params[:name]
    @application.redirect_uri = @application_params[:redirect_uri]
    @application.owner = current_seller
    @application.owner_type = "User"

    if params[:signed_blob_id].present?
      @application.file.attach(params[:signed_blob_id])
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

    @application.name = @application_params[:name] if @application_params[:name].present?
    @application.redirect_uri = @application_params[:redirect_uri] if @application_params[:redirect_uri].present?
    if params[:signed_blob_id].present?
      @application.file.attach(params[:signed_blob_id])
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
end
