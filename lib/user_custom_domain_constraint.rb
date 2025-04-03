# frozen_string_literal: true

class UserCustomDomainConstraint
  def self.matches?(request)
    Subdomain.find_seller_by_request(request).present? ||
      CustomDomain.find_by_host(request.host)&.user&.username.present? ||
      SubdomainRedirectorService.new.redirect_url_for(request).present?
  end
end
