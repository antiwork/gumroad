# frozen_string_literal: true

class DiscoverDomainConstraint
  def self.matches?(request)
    request.host == VALID_DISCOVER_REQUEST_HOST
  end
end
