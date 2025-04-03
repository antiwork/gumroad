# frozen_string_literal: true

class Oauth::ApplicationsController < Doorkeeper::ApplicationsController
  protect_from_forgery

  include CsrfTokenInjector
  include Impersonate

  before_action :authenticate_user!
  before_action :set_display_vars
  before_action :set_application_params, only: %i[create update]
  before_action :set_application, only: %i[edit update destroy]
  after_action :verify_authorized, except: %i[index new show]

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
      render json: {
        success: true,
        message: "Application created.",
        redirect_location: oauth_application_path(@application.external_id)
      }
    else
      render json: { success: false, message: @application.errors.full_messages.to_sentence }
    end
  end

  def show
    redirect_to edit_oauth_application_path(params[:id])
  end

  def edit
    @title = "Update application"
    authorize([:settings, :authorized_applications, @application])

    @react_component_props = SettingsPresenter.new(pundit_user:).application_props(@application)
  end

  def update
    authorize([:settings, :authorized_applications, @application])

    @application.name = @application_params[:name] if @application_params[:name].present?
    @application.redirect_uri = @application_params[:redirect_uri] if @application_params[:redirect_uri].present?
    if params[:signed_blob_id].present?
      @application.file.attach(params[:signed_blob_id])
    end

    if @application.save
      render json: { success: true, message: "Application updated." }
    else
      render json: { success: false, message: @application.errors.full_messages.to_sentence },
             status: :unprocessable_entity
    end
  end

  def destroy
    authorize([:settings, :authorized_applications, @application])

    @application.mark_deleted!

    head :ok
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

    # set display instance vars here because we don't inherit from application controller
    def set_display_vars
      @body_id = "app"
    end
end
