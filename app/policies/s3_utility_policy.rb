# frozen_string_literal: true

# Products > Edit product
class S3UtilityPolicy < ApplicationPolicy
  def generate_multipart_signature?
    user.role_admin_for?(seller) ||
    user.role_marketing_for?(seller)
  end

  def current_utc_time_string?
    generate_multipart_signature?
  end

  def cdn_url_for_blob?
    generate_multipart_signature?
  end
end
