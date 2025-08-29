# frozen_string_literal: true

class AffiliateRequestsController < ApplicationController
  include CustomDomainConfig

  PUBLIC_ACTIONS = %i[new create]
  before_action :authenticate_user!, except: PUBLIC_ACTIONS

  before_action :set_user_and_custom_domain_config, only: %i[new create]
  before_action :check_if_needs_redirect, only: :new
  before_action :ensure_creator_has_enabled_affiliate_requests, only: %i[new create]
  before_action :set_affiliate_request, only: %i[approve ignore]

  def new
    @title = "Become an affiliate for #{@user.display_name}"
    @profile_presenter = ProfilePresenter.new(
      pundit_user:,
      seller: @user,
    )
    @hide_layouts = true
  end

  def create
    @affiliate_request = @user.affiliate_requests.new(permitted_create_params)
    @affiliate_request.locale = params[:locale] || "en"

    if @affiliate_request.save
      @affiliate_request.approve! if Feature.active?(:auto_approve_affiliates, @user)
      update_logged_in_user_name_if_needed(permitted_create_params[:name])
      render json: { success: true, requester_has_existing_account: User.exists?(email: @affiliate_request.email) }
    else
      render json: { success: false, error: @affiliate_request.errors.full_messages.first }
    end
  end

  def update
    affiliate_request = current_seller.affiliate_requests.find_by_external_id!(params[:id])
    authorize affiliate_request

    action_name = permitted_update_params[:action]

    unless affiliate_request.can_perform_action?(action_name)
      render json: { success: false, error: "#{affiliate_request.name}'s affiliate request has been already processed." }
      return
    end

    begin
      if action_name == AffiliateRequest::ACTION_APPROVE
        affiliate_request.approve!
      elsif action_name == AffiliateRequest::ACTION_IGNORE
        affiliate_request.ignore!
      else
        render json: { success: false, error: "#{action_name} is not a valid affiliate request action" }
        return
      end

      render json: { success: true, affiliate_request:, requester_has_existing_account: User.exists?(email: affiliate_request.email) }
    rescue ActiveRecord::RecordInvalid => e
      render json: { success: false, error: e.message }
    end
  end

  def approve
    begin
      perform_action_if_permitted(AffiliateRequest::ACTION_APPROVE) do
        @affiliate_request.approve!
        @message = "Approved #{@affiliate_request.name}'s affiliate request."
      end
    rescue ActiveRecord::RecordInvalid => e
      @message = "An error encountered while approving #{@affiliate_request.name}'s affiliate request - #{e.message}."
    end

    render :email_link_status
  end

  def ignore
    begin
      perform_action_if_permitted(AffiliateRequest::ACTION_IGNORE) do
        @affiliate_request.ignore!
        @message = "Ignored #{@affiliate_request.name}'s affiliate request."
      end
    rescue ActiveRecord::RecordInvalid => e
      @message = "An error encountered while ignoring #{@affiliate_request.name}'s affiliate request - #{e.message}."
    end

    render :email_link_status
  end

  def approve_all
    authorize AffiliateRequest

    pending_requests = current_seller.affiliate_requests.unattended
    pending_requests.find_each(&:approve!)
    render json: { success: true }
  rescue ActiveRecord::RecordInvalid, StateMachines::InvalidTransition
    render json: { success: false }
  end

  private
    def ensure_creator_has_enabled_affiliate_requests
      respond_with_404 unless @user.self_service_affiliate_products.enabled.exists?
    end

    def check_if_needs_redirect
      if !@is_user_custom_domain && @user.subdomain_with_protocol.present?
        redirect_to custom_domain_new_affiliate_request_url(host: @user.subdomain_with_protocol),
                    status: :moved_permanently, allow_other_host: true
      end
    end

    def set_affiliate_request
      @affiliate_request = current_seller.affiliate_requests.find_by_external_id!(params[:id])
    end

    def permitted_create_params
      params.require(:affiliate_request).permit(:name, :email, :promotion_text)
    end

    def permitted_update_params
      params.require(:affiliate_request).permit(:action)
    end

    def perform_action_if_permitted(action)
      if @affiliate_request.can_perform_action?(action)
        yield
      else
        @message = "#{@affiliate_request.name}'s affiliate request has been already processed."
      end
    end

    def respond_with_404
      respond_to do |format|
        format.html { e404 }
        format.json { return e404_json }
      end
    end

    def update_logged_in_user_name_if_needed(name)
      return if logged_in_user.blank?
      return if logged_in_user.name.present?

      # Do a best effort to update name if possible;
      # Do not raise if record cannot be saved as the user cannot fix the issue within this context
      logged_in_user.update(name:)
    end
end
