# frozen_string_literal: true

class Settings::ProfileController < Settings::BaseController
  before_action :authorize

  def show
    profile_presenter = ProfilePresenter.new(pundit_user:, seller: current_seller)

    render inertia: "Settings/Profile/Show", props: settings_presenter.profile_props.merge(
      profile_presenter.profile_settings_props(request:)
    )
  end

  def update
    return respond_error("You have to confirm your email address before you can do that.") unless current_seller.confirmed?

    if permitted_params[:profile_picture_blob_id].present?
      return respond_error("The logo is already removed. Please refresh the page and try again.") if ActiveStorage::Blob.find_signed(permitted_params[:profile_picture_blob_id]) .nil?
      begin
        current_seller.avatar.attach permitted_params[:profile_picture_blob_id]
      rescue ActiveRecord::RecordNotUnique
        current_seller.avatar.reload
      end
    elsif permitted_params.has_key?(:profile_picture_blob_id) && current_seller.avatar.attached?
      current_seller.avatar.purge
    end

    begin
      ActiveRecord::Base.transaction do
        seller_profile = current_seller.seller_profile
        section_ids_by_param_id = {}
        if permitted_params[:sections]
          save_service = SellerProfileSections::SaveService.new(seller: current_seller)
          permitted_params[:sections].each do |section_attributes|
            section = save_service.upsert!(section_attributes)
            section_ids_by_param_id[section_attributes[:id]] = section.id
          end
        end
        if permitted_params[:tabs]
          tabs = permitted_params[:tabs].as_json
          # Resolve each tab's section references to real db ids, dropping any that no longer
          # resolve (client GUIDs decrypt to nil) so stale references can't be persisted.
          all_references_resolved = true
          tabs.each do |tab|
            tab["sections"] = Array(tab["sections"]).filter_map do |param_id|
              resolved_id = section_ids_by_param_id[param_id] || ObfuscateIds.decrypt(param_id)
              all_references_resolved = false if resolved_id.nil?
              resolved_id
            end
          end
          # Only prune sections when every reference resolved. Otherwise an unresolvable
          # reference would make a still-referenced section look orphaned and destroy it.
          if all_references_resolved
            current_seller.seller_profile_sections.on_profile.each do |section|
              section.destroy! if tabs.none? { _1["sections"].include?(section.id) }
            end
          end
          seller_profile.json_data["tabs"] = tabs
        end
        seller_profile.assign_attributes(permitted_params[:seller_profile]) if permitted_params[:seller_profile].present?
        seller_profile.save!
        current_seller.update!(permitted_params[:user]) if permitted_params[:user]
        current_seller.clear_products_cache if permitted_params[:profile_picture_blob_id].present?
      end
      respond_success
    rescue ActiveRecord::RecordInvalid => e
      respond_error(e.record.errors.full_messages.to_sentence)
    rescue ActiveRecord::SubclassNotFound
      respond_error("Invalid section type")
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

    def respond_error(message)
      if request.inertia?
        redirect_to settings_profile_path, alert: message
      else
        render json: { success: false, error_message: message }
      end
    end

    def respond_success
      if request.inertia?
        redirect_to settings_profile_path, status: :see_other, notice: "Changes saved!"
      else
        render json: { success: true }
      end
    end
end
