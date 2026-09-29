# frozen_string_literal: true

module PiracyReportHelpers
  # A seller who passes PiracyReports::Eligibility: flag on, confirmed email, payout setup, and a
  # published product with one successful sale.
  def create_piracy_seller_with_product
    seller = create(:user)
    create(:user_compliance_info, user: seller)
    Feature.activate_user(:piracy_reports, seller)
    product = create(:product, user: seller)
    create(:purchase, link: product)
    [seller, product]
  end
end

RSpec.configure do |config|
  config.include PiracyReportHelpers
end
