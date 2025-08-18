# frozen_string_literal: true

require "spec_helper"

describe DisputeEvidence::GenerateRefundPolicyImageService, type: :system, js: true do
  let(:purchase) { create(:purchase) }
  let(:url) do
    Rails.application.routes.url_helpers.purchase_product_url(
      purchase.external_id,
      host: DOMAIN,
      protocol: PROTOCOL,
      anchor: nil,
    )
  end

  before do
    visit receipt_purchase_path(purchase.external_id, email: purchase.email) # Needed to boot the server
  end

  describe ".perform" do
    it "generates a JPG image" do
      expect_any_instance_of(Selenium::WebDriver::Driver).to receive(:quit)
      binary_data = described_class.perform(url:, mobile_purchase: false, open_fine_print_modal: false, max_size_allowed: 3_000_000.bytes)
      expect(binary_data).to start_with("\xFF\xD8".b)
      expect(binary_data).to end_with("\xFF\xD9".b)
    end

    context "when the image is too large" do
      it "raises an error" do
        expect_any_instance_of(Selenium::WebDriver::Driver).to receive(:quit)
        expect do
          described_class.perform(url:, mobile_purchase: false, open_fine_print_modal: false, max_size_allowed: 1_000.bytes)
        end.to raise_error(DisputeEvidence::GenerateRefundPolicyImageService::ImageTooLargeError)
      end
    end
  end
end
