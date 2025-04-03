# frozen_string_literal: true

class GumroadDomainConstraint
  def self.matches?(request)
    VALID_REQUEST_HOSTS.include?(request.host)
  end
end
