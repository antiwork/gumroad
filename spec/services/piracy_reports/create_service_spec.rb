# frozen_string_literal: true

require "spec_helper"

describe PiracyReports::CreateService do
  let(:url) { "https://example.net/design-course" }

  def call(seller:, product:, url: self.url, source: "support")
    described_class.new(seller:, product:, url:, source:, ticket_url: "https://helper.example.com/tickets/1").call
  end

  context "with an eligible seller" do
    let!(:seller_and_product) { create_piracy_seller_with_product }
    let(:seller) { seller_and_product.first }
    let(:product) { seller_and_product.last }

    it "creates a requested report with the source and ticket" do
      result = call(seller:, product:)

      expect(result).to be_success
      expect(result.report).to have_attributes(state: "requested", source: "support", ticket_url: "https://helper.example.com/tickets/1", seller:, product:)
    end

    it "rejects a URL that is not http or https" do
      result = call(seller:, product:, url: "example.net/design-course")

      expect(result.errors).to eq(["The URL must start with http:// or https://"])
    end

    it "rejects a page hosted on Gumroad" do
      result = call(seller:, product:, url: "https://#{ROOT_DOMAIN.split(":").first}/l/abc")

      expect(result.errors).to eq(["Pages hosted on Gumroad are reported through the terms of service process"])
    end

    it "rejects a URL that embeds a second URL" do
      result = call(seller:, product:, url: "https://example.net/copy/also-remove-https://victim.example/store")

      expect(result.errors).to eq(["Url must not contain another URL"])
    end

    it "rejects a URL or ticket link longer than its column instead of raising" do
      long_url = "https://example.net/#{"a" * PiracyReport::MAX_REPORTED_URL_LENGTH}"

      result = call(seller:, product:, url: long_url)
      ticket = described_class.new(seller:, product:, url:, source: "support", ticket_url: "https://helper.example.com/#{"a" * 1024}").call

      expect(result.errors).to eq(["Url is too long (maximum is 500 characters)"])
      expect(ticket.errors).to eq(["Ticket url is too long (maximum is 1024 characters)"])
    end

    it "rejects a page served from a seller's custom domain, with or without www" do
      create(:custom_domain, domain: "example.net")
      create(:custom_domain, domain: "www.example.org")

      expect(call(seller:, product:, url: "https://example.net/design-course").errors).to eq(["Pages hosted on Gumroad are reported through the terms of service process"])
      expect(call(seller:, product:, url: "https://example.org/design-course").errors).to eq(["Pages hosted on Gumroad are reported through the terms of service process"])
    end

    it "accepts a page on a domain that a seller removed" do
      create(:custom_domain, domain: "example.net", deleted_at: Time.current)

      expect(call(seller:, product:, url: "https://example.net/design-course")).to be_success
    end

    it "rejects the same page reported again under a different spelling" do
      call(seller:, product:)

      result = call(seller:, product:, url: "http://www.example.net/design-course/")

      expect(result.errors).to eq(["This page has already been reported for this product"])
    end

    it "rejects a report once the monthly limit is reached" do
      stub_const("PiracyReport::MONTHLY_LIMIT", 2)
      2.times { |i| call(seller:, product:, url: "https://example.net/copy-#{i}") }

      result = call(seller:, product:, url: "https://example.net/copy-3")

      expect(result.errors).to eq(["The monthly limit of 2 reports has been reached"])
    end

    it "counts and inserts while holding the seller's row lock" do
      expect(seller).to receive(:with_lock).and_call_original

      expect(call(seller:, product:)).to be_success
    end

    it "counts only reports from the current month toward the limit" do
      stub_const("PiracyReport::MONTHLY_LIMIT", 1)
      create(:piracy_report, seller:, product:, url: "https://example.net/old-copy", created_at: 2.months.ago)

      expect(call(seller:, product:)).to be_success
    end
  end

  describe "eligibility" do
    it "rejects a seller without the feature flag" do
      seller, product = create_piracy_seller_with_product
      Feature.deactivate_user(:piracy_reports, seller)

      expect(call(seller:, product:).errors).to include("Piracy reports are not enabled for this seller")
    end

    it "rejects a seller with an unconfirmed email" do
      seller, product = create_piracy_seller_with_product
      seller.update!(confirmed_at: nil)

      expect(call(seller:, product:).errors).to include(PiracyReports::Eligibility.store_agent_gate_error)
    end

    it "rejects a seller with no completed payout" do
      seller = create(:user)
      create(:user_compliance_info, user: seller)
      Feature.activate_user(:piracy_reports, seller)
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(User::MIN_SALES_CENTS_VALUE_FOR_STORE_AGENT)
      product = create(:product, user: seller)

      result = nil
      expect { result = call(seller:, product:) }.not_to change(PiracyReport, :count)
      expect(result.errors).to include(PiracyReports::Eligibility.store_agent_gate_error)
    end

    it "reports the suspension itself, not the earned-access steps" do
      seller, product = create_piracy_seller_with_product
      seller.update!(user_risk_state: "suspended_for_fraud")

      expect(call(seller:, product:).errors).to eq(["The seller's account is suspended"])
    end

    it "rejects a seller under the store agent's sales bar" do
      seller, product = create_piracy_seller_with_product
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(User::MIN_SALES_CENTS_VALUE_FOR_STORE_AGENT - 1)

      expect(call(seller:, product:).errors).to include(PiracyReports::Eligibility.store_agent_gate_error)
    end

    it "rejects a seller whose payout record has no legal name to print in the notice" do
      seller, product = create_piracy_seller_with_product
      seller.alive_user_compliance_info.update_columns(first_name: nil, last_name: nil)

      expect(call(seller:, product:).errors).to include("The seller's payout record has no legal name to print in the notice")
    end

    it "accepts a seller whose payout record has no street address, since the notice does not print it" do
      seller, product = create_piracy_seller_with_product
      seller.alive_user_compliance_info.update_columns(street_address: nil)

      expect(call(seller:, product:)).to be_success
    end

    it "rejects a product that belongs to another seller" do
      seller, = create_piracy_seller_with_product
      _, other_product = create_piracy_seller_with_product

      expect(call(seller:, product: other_product).errors).to include("The product does not belong to the seller")
    end

    it "rejects an unpublished product" do
      seller, product = create_piracy_seller_with_product
      product.update_columns(purchase_disabled_at: Time.current)

      expect(call(seller:, product:).errors).to include("The product is not published")
    end

    it "rejects a product with no successful sales, even when the seller passes the store agent's gate" do
      seller, = create_piracy_seller_with_product
      product = create(:product, user: seller)

      expect(call(seller:, product:).errors).to eq(["The product has no successful sales"])
    end
  end
end
