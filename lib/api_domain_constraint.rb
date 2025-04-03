# frozen_string_literal: true

class ApiDomainConstraint
  def self.matches?(request)
    Rails.env.development? || VALID_API_REQUEST_HOSTS.include?(request.host)
  end
end
