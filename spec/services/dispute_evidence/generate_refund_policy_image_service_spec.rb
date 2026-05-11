# frozen_string_literal: true

require "spec_helper"

describe DisputeEvidence::GenerateRefundPolicyImageService do
  describe "#calculate_height" do
    let(:service) { described_class.new("https://example.com", mobile_purchase: false, open_fine_print_modal: false, max_size_allowed: 5_000_000) }
    let(:driver) { instance_double(Selenium::WebDriver::Driver) }
    let(:document_height) { 1_000 }
    let(:article_height) { 1_500 }

    before do
      allow(driver).to receive(:execute_script).with(/Math\.max/).and_return(document_height)
    end

    context "when the <article> element is mounted before the timeout" do
      before do
        fake_wait = instance_double(Selenium::WebDriver::Wait)
        allow(Selenium::WebDriver::Wait).to receive(:new).and_return(fake_wait)
        allow(fake_wait).to receive(:until).and_return(true)
        allow(driver).to receive(:execute_script).with(/parentElement\?\.scrollHeight/).and_return(article_height)
      end

      it "returns the larger of the article and document heights" do
        expect(service.send(:calculate_height, driver, open_fine_print_modal: false)).to eq(article_height)
      end
    end

    context "when the <article> element never mounts" do
      before do
        fake_wait = instance_double(Selenium::WebDriver::Wait)
        allow(Selenium::WebDriver::Wait).to receive(:new).and_return(fake_wait)
        allow(fake_wait).to receive(:until).and_raise(Selenium::WebDriver::Error::TimeoutError)
      end

      it "falls back to the document height without raising" do
        expect(service.send(:calculate_height, driver, open_fine_print_modal: false)).to eq(document_height)
        expect(driver).not_to have_received(:execute_script).with(/parentElement/)
      end
    end
  end
end

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
