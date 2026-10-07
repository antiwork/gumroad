# frozen_string_literal: true

module PiracyReportHelpers
  # A seller who passes PiracyReports::Eligibility: flag on, the store agent's earned access
  # (confirmed, a completed payout, $100 in sales) and a payout record carrying a legal name.
  def create_piracy_seller_with_product
    seller = create(:user)
    create(:user_compliance_info, user: seller)
    Feature.activate_user(:piracy_reports, seller)
    create(:payment_completed, user: seller)
    # sales_cents_total is an Elasticsearch aggregation, and eligibility is checked on whatever
    # User object the caller holds, so the stub goes on the class the way the agent specs do it.
    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(User::MIN_SALES_CENTS_VALUE_FOR_STORE_AGENT)
    product = create(:product, user: seller)
    create(:purchase, link: product)
    [seller, product]
  end
end

RSpec.configure do |config|
  config.include PiracyReportHelpers
end
