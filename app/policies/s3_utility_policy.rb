# frozen_string_literal: true

class S3UtilityPolicy < ApplicationPolicy
  def generate_multipart_signature?
    user.present?
  end

  def current_utc_time_string?
    user.present?
  end

  def cdn_url_for_blob?
    user.present?
  end
end
