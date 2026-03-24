# frozen_string_literal: true

module PageMeta::Analytics
  extend ActiveSupport::Concern

  include PageMeta::Base

  private
    def set_analytics_meta_tags
      set_meta_tag(property: "gr:google_analytics:enabled", content: analytics_enabled?.to_s)
      set_meta_tag(property: "gr:fb_pixel:enabled", content: analytics_enabled?.to_s)
      set_meta_tag(property: "gr:logged_in_user:id", content: logged_in_user.present? ? logged_in_user.external_id : "")
      set_meta_tag(property: "gr:page:type", content: "")
      set_meta_tag(property: "gr:facebook_sdk:enabled", content: analytics_enabled?.to_s)
    end

    def analytics_enabled?(seller: @user || current_seller)
      return false if @disable_third_party_analytics
      return true unless seller.present?
      return false if !Rails.env.production? && !Rails.env.staging?

      !seller.disable_third_party_analytics?
    end

    def disable_third_party_analytics!
      @disable_third_party_analytics = true
    end
end
