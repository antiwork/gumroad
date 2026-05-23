# frozen_string_literal: true

require "test_helper"

class PurchaseReceiptTest < ActiveSupport::TestCase
  self.described_class = Purchase::Receipt



  context_ Purchase::Receipt do
    let(:purchase) { create(:purchase) }

  context_ "#receipt_email_info" do
      let(:charge) { create(:charge, purchases: [purchase]) }
      let(:order) { charge.order }

  context_ "without email info records" do
  test "returns nil" do
          expect(purchase.receipt_email_info).to be_nil
        end
      end

  context_ "when the purchase does not use charge receipt" do
        let!(:email_info_from_purchase) do
          create(
            :customer_email_info,
            purchase_id: purchase.id,
            email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
          )
        end

  test "returns email_info from purchase" do
          expect(purchase.receipt_email_info).to eq(email_info_from_purchase)
        end
      end

  context_ "when the purchase uses charge receipt" do
        let!(:email_info_from_charge) do
          create(
            :customer_email_info,
            purchase_id: nil,
            email_name: SendgridEventInfo::RECEIPT_MAILER_METHOD,
            email_info_charge_attributes: { charge_id: charge.id }
          )
        end

  test "returns the email info" do
          expect(purchase.receipt_email_info).to eq(email_info_from_charge)
        end
      end
    end

  context_ "#has_invoice?" do
  test "returns true" do
        expect(purchase.has_invoice?).to be(true)
      end

  context_ "when is a free trial" do
        let(:purchase) { create(:free_trial_membership_purchase) }

  test "returns false" do
          expect(purchase.has_invoice?).to be(false)
        end
      end

  context_ "when is a free purchase" do
        let(:purchase) { create(:free_purchase) }

  test "returns false" do
          expect(purchase.has_invoice?).to be(false)
        end
      end
    end

  context_ "#send_receipt" do
  test "enqueues the receipt job" do
        purchase.send_receipt
        expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(purchase.id).on("critical")
      end

  context_ "when the purchase uses a charge receipt" do
        before do
          allow_any_instance_of(Purchase).to receive(:uses_charge_receipt?).and_return(true)
        end

  test "doesn't enqueue the receipt job" do
          purchase.send_receipt
          expect(SendPurchaseReceiptJob).not_to have_enqueued_sidekiq_job(purchase.id)
        end
      end
    end

  context_ "#resend_receipt" do
      let(:product) { create(:product_with_pdf_file) }
      let(:gift) { create(:gift, link: product) }
      let(:purchase) { create(:purchase, link: product, is_gift_sender_purchase: true, gift_given: gift) }
      let!(:url_redirect) { create(:url_redirect, purchase:, link: product) }
      let(:giftee_purchase) { create(:purchase, link: product, gift_received: gift) }
      let!(:giftee_url_redirect) { create(:url_redirect, purchase: giftee_purchase, link: product) }

  context_ "when product has no stampable files" do
  test "enqueues SendPurchaseReceiptJob using the critical queue" do
          purchase.resend_receipt

          expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(purchase.id).on("critical")
          expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(giftee_purchase.id).on("critical")
        end
      end

  context_ "when product has stampable files" do
        before do
          product.product_files.pdf.first.update!(pdf_stamp_enabled: true)
        end

  test "enqueues SendPurchaseReceiptJob using the default queue" do
          purchase.resend_receipt

          expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(purchase.id).on("default")
          expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(giftee_purchase.id).on("default")
        end
      end
    end
  end
end
