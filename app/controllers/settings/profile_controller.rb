# frozen_string_literal: true

class Settings::ProfileController < Settings::BaseController
  StaleProfileError = Class.new(StandardError)
  private_constant :StaleProfileError
  STALE_PROFILE_MESSAGE = "Your profile was changed somewhere else. Please reload the page and try again."
  private_constant :STALE_PROFILE_MESSAGE

  before_action :authorize

  def show
    profile_presenter = ProfilePresenter.new(pundit_user:, seller: current_seller)

    render inertia: "Settings/Profile/Show", props: profile_presenter.profile_settings_props(request:)
  end

  def update
    return respond_error("You have to confirm your email address before you can do that.") unless current_seller.confirmed?

    # Reject a stale layout before mutating anything (including the avatar), so a rejected save leaves
    # the profile untouched. The locked re-check inside the transaction is authoritative; this is an
    # early-out that avoids a partial write - e.g. attaching/purging the avatar - when we already know
    # the layout is stale.
    return respond_error(STALE_PROFILE_MESSAGE) if stale_layout_submission?

    if permitted_params[:profile_picture_blob_id].present?
      return respond_error("The logo is already removed. Please refresh the page and try again.") if ActiveStorage::Blob.find_signed(permitted_params[:profile_picture_blob_id]).nil?
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
        # Optimistic concurrency: lock the profile and reject the save if its pages/sections were
        # changed elsewhere since this editor loaded. Otherwise this request would overwrite the
        # layout with a stale snapshot and drop or orphan sections another session added. A brand
        # new profile has nothing to conflict with, and settings-only saves don't touch the layout.
        if (permitted_params[:tabs] || permitted_params[:sections]) && seller_profile.persisted?
          seller_profile.lock!
          # A persisted profile must be saved against a matching version. A missing/blank version
          # means the editor loaded before this profile row existed (another session has created it
          # since), so the submitted layout is stale too. Re-checked here under the lock in case the
          # layout changed between the early-out above and this transaction.
          raise StaleProfileError if submitted_version_stale?(seller_profile)
        end
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
          # reference would make a still-referenced section look orphaned and destroy it. The
          # version check above guarantees this tab list isn't stale, so a missing section was
          # genuinely removed here rather than added by another session.
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
    rescue StaleProfileError
      respond_error(STALE_PROFILE_MESSAGE)
    rescue ActiveRecord::RecordInvalid => e
      respond_error(e.record.errors.full_messages.to_sentence)
    rescue ActiveRecord::SubclassNotFound
      respond_error("Invalid section type")
    end
  end

  private
    def stale_layout_submission?
      return false unless permitted_params[:tabs] || permitted_params[:sections]

      seller_profile = current_seller.seller_profile
      seller_profile.persisted? && submitted_version_stale?(seller_profile)
    end

    def submitted_version_stale?(seller_profile)
      permitted_params[:profile_version].blank? || seller_profile.layout_version.iso8601(6) != permitted_params[:profile_version]
    end

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
        redirect_to profile_path, alert: message
      else
        render json: { success: false, error_message: message }
      end
    end

    def respond_success
      if request.inertia?
        redirect_to profile_path, status: :see_other, notice: "Changes saved!"
      else
        render json: { success: true }
      end
    end
end
