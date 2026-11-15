# frozen_string_literal: true

require "spec_helper"

describe Purchase, "download page availability" do
  let(:product) { create(:product_with_pdf_file) }
  let(:purchase) { create(:purchase, link: product) }

  before do
    product.product_files.pdf.first.update!(pdf_stamp_enabled: true)
    purchase.create_url_redirect!
  end

  context "when a PDF stamp is still pending" do
    it "exposes the download page but not the content" do
      expect(purchase.has_content?).to be false
      expect(purchase.has_download_page?).to be true
      expect(purchase.purchase_response[:content_url]).to eq purchase.url_redirect.download_page_url
    end
  end

  context "when the webhook failed" do
    before { purchase.update!(webhook_failed: true) }

    it "withholds the download page" do
      expect(purchase.has_download_page?).to be false
      expect(purchase.purchase_response[:content_url]).to be_nil
    end
  end

  context "when there is no url redirect" do
    before { purchase.url_redirect.destroy! && purchase.reload }

    it "withholds the download page" do
      expect(purchase.has_download_page?).to be false
    end
  end
end
