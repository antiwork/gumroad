# frozen_string_literal: true

require "test_helper"

class OrderTest < ActiveSupport::TestCase
  self.described_class = Order



  context_ Order do
    let(:product) { create(:product) }
    let(:purchase) { create(:purchase, link: product) }
    let(:order) { create(:order, purchases: [purchase]) }

  context_ "#receipt_for_gift_receiver?" do
  context_ "when the purchase is not for a gift receiver" do
  test "returns false" do
          expect(order.receipt_for_gift_receiver?).to be(false)
        end
      end

  context_ "when the purchase is for a gift receiver" do
        let(:gift) { create(:gift) }
        let!(:gifter_purchase) { create(:purchase, link: gift.link, gift_given: gift, is_gift_sender_purchase: true) }
        let(:purchase) { create(:purchase, link: gift.link, gift_received: gift, is_gift_receiver_purchase: true) }

  test "returns true" do
          expect(order.receipt_for_gift_receiver?).to be(true)
        end
      end

  context_ "when there are multiple purchases per order" do
        let(:other_purchase) { create(:purchase) }

        before do
          order.purchases << other_purchase
        end

  test "raises" do
          expect { order.receipt_for_gift_receiver? }.to raise_error(NotImplementedError).with_message("Not supported for multi-item orders")
        end
      end
    end

  context_ "#receipt_for_gift_sender?" do
  context_ "when the purchase is not for a gift sender" do
  test "returns false" do
          expect(order.receipt_for_gift_sender?).to be(false)
        end
      end

  context_ "when the purchase is for a gift sender" do
        let(:gift) { create(:gift) }

        before do
          purchase.update!(is_gift_sender_purchase: true, gift_given: gift)
        end

  test "returns true" do
          expect(order.receipt_for_gift_sender?).to be(true)
        end
      end

  context_ "when there are multiple purchases per order" do
        let(:other_purchase) { create(:purchase) }

        before do
          order.purchases << other_purchase
        end

  test "raises" do
          expect { order.receipt_for_gift_sender? }.to raise_error(NotImplementedError).with_message("Not supported for multi-item orders")
        end
      end
    end

  context_ "#email" do
  test "returns the email of the purchase" do
        expect(order.email).to eq(purchase.email)
      end
    end

  context_ "#locale" do
  test "returns the locale of the purchase" do
        expect(order.locale).to eq(purchase.locale)
      end
    end

  context_ "#test?" do
  context_ "when the purchase is not a test purchase" do
  test "returns false" do
          expect(order.test?).to eq(false)
        end
      end

  context_ "when the purchase is a test purchase" do
        before do
          allow_any_instance_of(Purchase).to receive(:is_test_purchase?).and_return(true)
        end

  test "returns true" do
          expect(order.test?).to eq(true)
        end
      end
    end

  context_ "#purchase_with_payment_as_orderable" do
      let(:purchase) { create(:failed_purchase) }
      let(:free_purchase) { create(:free_purchase) }

      before do
        order.purchases << free_purchase
      end

  context_ "without a successful paid purchase" do
  test "returns the free purchase" do
          expect(order.send(:purchase_with_payment_as_orderable)).to eq(free_purchase)
        end
      end

  context_ "with a successful paid purchase" do
        let(:paid_purchase) { create(:purchase) }

        before do
          order.purchases << paid_purchase
        end

  test "returns the paid purchase" do
          expect(order.send(:purchase_with_payment_as_orderable)).to eq(paid_purchase)
        end
      end
    end

  context_ "Purchase attributes" do
      let(:purchase) { create(:failed_purchase) }
      let(:free_purchase) { create(:free_purchase) }
      let(:paid_purchase) { create(:purchase) }
      let(:physical_product) { create(:product, :is_physical) }
      let(:physical_purchase) { create(:physical_purchase, link: physical_product) }

      before do
        order.purchases << free_purchase
        order.purchases << paid_purchase
        order.purchases << physical_purchase
      end

  test "returns the correct purchase attributes" do
        expect(order.send(:purchase_as_orderable)).to eq(free_purchase)
        expect(order.send(:purchase_with_payment_as_orderable)).to eq(paid_purchase)

        expect(order.card_type).to eq(paid_purchase.card_type)
        expect(order.card_visual).to eq(paid_purchase.card_visual)
      end
    end

  context_ "#purchase_as_orderable" do
      let(:purchase) { create(:failed_purchase) }
      let(:test_purchase) { create(:test_purchase) }
      let(:paid_purchase) { create(:purchase) }

      before do
        order.purchases << test_purchase
        order.purchases << paid_purchase
      end

  test "returns first successful purchase" do
        expect(order.send(:purchase_as_orderable)).to eq(test_purchase)
      end
    end

  context_ "#send_charge_receipts", :vcr do
      let(:order) { create(:order) }
      let(:product_one) { create(:product) }
      let(:purchase_one) { create(:purchase, link: product_one) }
      let!(:charge_one) { create(:charge, order:, purchases: [purchase_one]) }
      let!(:charge_two) { create(:charge, order:, purchases: [create(:purchase)]) }
      let!(:failed_charge) { create(:charge, order:, purchases: [create(:failed_purchase)]) }

  test "sends charge receipts" do
        order.send_charge_receipts
        expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(charge_one.id).on("critical")
        expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(charge_two.id).on("critical")
        expect(SendChargeReceiptJob).not_to have_enqueued_sidekiq_job(failed_charge.id)
      end

  context_ "when a product has stampable PDFs" do
        before do
          product_one.product_files << create(:readable_document, pdf_stamp_enabled: true)
          purchase_one.create_url_redirect!
        end

  test "enqueues the job on the default job queue" do
          order.send_charge_receipts
          expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(charge_one.id).on("default")
          expect(SendChargeReceiptJob).to have_enqueued_sidekiq_job(charge_two.id).on("critical")
          expect(SendChargeReceiptJob).not_to have_enqueued_sidekiq_job(failed_charge.id)
        end
      end
    end

  context_ "#successful_charges", :vcr do
      let(:order) { create(:order) }
      let!(:charge_one) { create(:charge, order:, purchases: [create(:purchase)]) }
      let!(:charge_two) { create(:charge, order:, purchases: [create(:purchase)]) }
      let!(:failed_charge) { create(:charge, order:, purchases: [create(:failed_purchase)]) }

  test "returns the successful charges" do
        expect(order.successful_charges).to eq([charge_one, charge_two])
      end
    end

  context_ "#unsubscribe_buyer" do
  test "calls unsubscribe_buyer on purchase" do
        allow_any_instance_of(Purchase).to receive(:unsubscribe_buyer).and_return("unsubscribed!")
        expect(order.unsubscribe_buyer).to eq("unsubscribed!")
      end
    end

  context_ "#schedule_review_reminder!" do
      let(:order) { create(:order) }
      let(:purchase) { create(:purchase) }
      let(:cart) { create(:cart) }

      before do
        order.cart = cart
      end

  context_ "when there is a successful and eligible purchase" do
  test "schedules a review reminder" do
          expect(OrderReviewReminderJob).to receive(:perform_in).with(ProductReview::REVIEW_REMINDER_DELAY, order.id)
          order.purchases << purchase
          order.save
        end

  context_ "when review_reminder_scheduled_at is present" do
          before { order.update(review_reminder_scheduled_at: Time.current) }

  test "does not schedule a review reminder" do
            expect(OrderReviewReminderJob).not_to receive(:perform_in)
            order.purchases << purchase
            order.save
          end
        end

  context_ "when purchases require shipping" do
          let(:physical_product) { create(:product, :is_physical) }
          let(:physical_purchase) { create(:physical_purchase, link: physical_product) }

  test "schedules a reminder with REVIEW_REMINDER_PHYSICAL_DELAY" do
            expect(OrderReviewReminderJob).to receive(:perform_in).with(ProductReview::REVIEW_REMINDER_PHYSICAL_DELAY, order.id)
            order.purchases << physical_purchase
            order.save
          end
        end
      end

  context_ "when there are no successful purchases" do
        let(:purchase) { create(:purchase_in_progress) }
  test "does not schedule a review reminder" do
          expect(OrderReviewReminderJob).not_to receive(:perform_in)
          order.purchases << purchase
          order.save
        end
      end

  context_ "when there are successful purchases but none are eligible" do
        let(:ineligible_purchase) { create(:purchase, :with_review) }

  test "does not schedule a review reminder" do
          expect(OrderReviewReminderJob).not_to receive(:perform_in)
          order.purchases << ineligible_purchase
          order.save
        end
      end
    end
  end
end
