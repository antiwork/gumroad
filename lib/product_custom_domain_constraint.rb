# frozen_string_literal: true

class ProductCustomDomainConstraint
  def self.matches?(request)
    CustomDomain.find_by_host(request.host)&.product.present?
  end
end
