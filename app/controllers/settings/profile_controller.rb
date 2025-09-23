# frozen_string_literal: true

class Settings::ProfileController < Sellers::BaseController
  before_action :authorize

  def show
    @title = "Settings"
    @profile_presenter = ProfilePresenter.new(pundit_user:, seller: current_seller)
    @settings_presenter = SettingsPresenter.new(pundit_user:)

    @react_component_props = @settings_presenter.profile_props.merge(
      @profile_presenter.profile_settings_props(request:)
    )
  end

  def update
    return render json: { success: false, error_message: "You have to confirm your email address before you can do that." } unless current_seller.confirmed?

    if permitted_params[:profile_picture_blob_id].present?
      return render json: { success: false, error_message: "The logo is already removed. Please refresh the page and try again." } if ActiveStorage::Blob.find_signed(permitted_params[:profile_picture_blob_id]).nil?
      current_seller.avatar.attach permitted_params[:profile_picture_blob_id]
    elsif permitted_params.has_key?(:profile_picture_blob_id) && current_seller.avatar.attached?
      current_seller.avatar.purge
    end

    begin
      ActiveRecord::Base.transaction do
        seller_profile = current_seller.seller_profile
        sections = current_seller.seller_profile_sections.on_profile
        if permitted_params[:tabs]
          tabs = permitted_params[:tabs].as_json
          tabs.each { |tab| (tab["sections"] ||= []).map! { ObfuscateIds.decrypt(_1) } }
          sections.each do |section|
            section.destroy! if tabs.none? { _1["sections"]&.include?(section.id) }
          end
          seller_profile.json_data["tabs"] = tabs
        end
        seller_profile.assign_attributes(permitted_params[:seller_profile]) if permitted_params[:seller_profile].present?
        seller_profile.save!
        current_seller.update!(permitted_params[:user]) if permitted_params[:user]

        current_seller.clear_products_cache if permitted_params[:profile_picture_blob_id].present?
        render json: { success: true }
      end
    rescue ActiveRecord::RecordInvalid => e
      render json: { success: false, error_message: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  end

  private
    def authorize
      super(profile_policy)
    end

    def permitted_params
      params.permit(policy(profile_policy).permitted_attributes)
    end

    def profile_policy
      [:settings, :profile]
    end
end
