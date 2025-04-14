# frozen_string_literal: true

class S3UtilityPolicy < ApplicationPolicy
  def generate_multipart_signature?
    external_ids_to_sign = record[:external_ids]
    unauthorized_ids = external_ids_to_sign - external_ids_authorized_for_signing
    unauthorized_ids.empty?
  end

  def current_utc_time_string?
    user.present?
  end

  def cdn_url_for_blob?
    user.present?
  end

  private
    def external_ids_authorized_for_signing
      [
        user.external_id,
        authorized_to_sign_for_seller? ? seller.external_id : nil
      ].compact
    end

    def authorized_to_sign_for_seller?
      user.role_admin_for?(seller) || user.role_marketing_for?(seller)
    rescue ActiveRecord::RecordNotFound
      false
    end
end
