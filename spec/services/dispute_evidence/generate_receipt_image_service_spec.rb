# frozen_string_literal: true

require "spec_helper"

describe DisputeEvidence::GenerateReceiptImageService, type: :system, js: true do
  let(:purchase) { create(:purchase) }

  describe ".perform" do
    it "generates a JPG receipt image" do
      expect_any_instance_of(Selenium::WebDriver::Driver).to receive(:quit)
      binary_data = described_class.perform(purchase)
      expect(binary_data).to start_with("\xFF\xD8".b)
      expect(binary_data).to end_with("\xFF\xD9".b)
    end
  end

  describe "#generate_html" do
    before do
      mailer_double = double(
        body: double(raw_source: "<html><body><p>receipt</p></body></html>"),
        from: ["support@example.com"],
        to: ["customer@example.com"],
        subject: "You bought #{purchase.link.name}"
      )
      expect(CustomerMailer).to receive(:receipt).with(purchase.id).and_return(mailer_double)
    end

    it "generates the HTML for the receipt" do
      expected_html = <<~HTML
          <!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.0 Transitional//EN" "http://www.w3.org/TR/REC-html40/loose.dtd">
          <html><body>
                  <div style="padding: 20px 20px">
                    <p><strong>Email receipt sent at:</strong> #{purchase.created_at}</p>
                    <p><strong>From:</strong> support@example.com</p>
                    <p><strong>To:</strong> customer@example.com</p>
                    <p><strong>Subject:</strong> You bought #{purchase.link.name}</p>
                  </div>
                  <hr>
                <p>receipt</p>
          </body></html>
      HTML
      html = described_class.new(purchase).send(:generate_html, purchase)
      expect(html).to eq(expected_html)
    end
  end
end
