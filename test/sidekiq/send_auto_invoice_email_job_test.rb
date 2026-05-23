# frozen_string_literal: true

require "test_helper"

class SendAutoInvoiceEmailJobTest < ActiveSupport::TestCase
  self.described_class = SendAutoInvoiceEmailJob



  context_ SendAutoInvoiceEmailJob do
    let(:buyer) { create(:user) }
    let(:product) { create(:product) }
    let(:purchase) { create(:purchase, link: product, purchaser: buyer) }

  context_ "when the buyer has billing details with auto-email enabled" do
      before do
        create(:billing_detail, purchaser: buyer, auto_email_invoice_enabled: true)
      end

  test "delivers the auto_invoice mail" do
        mailer = double(deliver_now: true)
        expect(CustomerMailer).to receive(:auto_invoice).with(purchase.id, nil).and_return(mailer)

        described_class.new.perform(purchase.id, nil)
      end
    end

  context_ "when the buyer has no billing details" do
  test "does not send the mail" do
        expect(CustomerMailer).not_to receive(:auto_invoice)
        described_class.new.perform(purchase.id, nil)
      end
    end

  context_ "when the buyer disabled auto-email" do
      before do
        create(:billing_detail, purchaser: buyer, auto_email_invoice_enabled: false)
      end

  test "does not send the mail" do
        expect(CustomerMailer).not_to receive(:auto_invoice)
        described_class.new.perform(purchase.id, nil)
      end
    end

  context_ "when the purchase has no associated logged-in buyer" do
      let(:anonymous_purchase) { create(:purchase, link: product, purchaser: nil) }

  test "does not send the mail" do
        expect(CustomerMailer).not_to receive(:auto_invoice)
        described_class.new.perform(anonymous_purchase.id, nil)
      end
    end
  end
end
