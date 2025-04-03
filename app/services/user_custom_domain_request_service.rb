# frozen_string_literal: true

class UserCustomDomainRequestService
  class << self
    def valid?(request)
      !GumroadDomainConstraint.matches?(request) && !DiscoverDomainConstraint.matches?(request) && CustomDomain.find_by_host(request.host)&.product.nil?
    end
  end
end
