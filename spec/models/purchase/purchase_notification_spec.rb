# frozen_string_literal: true

require "spec_helper"

describe "Purchase Notifications", :vcr do
  include CurrencyHelper
  include ProductsHelper

  def verify_balance(user, expected_balance)
    expect(user.unpaid_balance_cents).to eq expected_balance
  end

  let(:ip_address) { "24.7.90.214" }
  let(:initial_balance) { 200 }
  let(:user) { create(:user, unpaid_balance_cents: initial_balance) }
  let(:link) { create(:product, user:) }
  let(:chargeable) { create :chargeable }

  describe "#send_notification_webhook" do
    it "schedules a `PostToPingEndpointsWorker` job" do
      purchase = create(:purchase)

      purchase.send_notification_webhook

      expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(purchase.id, purchase.url_parameters)
    end

    it "does not schedule a PostToPingEndpointsWorker job if the transaction creating the purchase was rolled back" do
      Purchase.transaction do
        create(:purchase).send_notification_webhook
        raise ActiveRecord::Rollback
      end

      expect(PostToPingEndpointsWorker.jobs.size).to eq(0)
    end

    it "schedules a PostToPingEndpointsWorker job if the transaction creating the purchase was committed" do
      purchase = nil
      Purchase.transaction do
        purchase = create(:purchase)
        purchase.send_notification_webhook
      end

      expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(purchase.id, purchase.url_parameters)
    end

    describe "with offer code" do
      before do
        @product = create(:product, price_cents: 600, user: create(:user, notification_endpoint: "http://notification.com"))
        @offer_code = create(:offer_code, products: [@product], code: "sxsw", amount_cents: 200)
        @purchase = create(:purchase, link: @product, seller: @product.user, price_cents: 400, email: "sahil@sahil.com",
                                      full_name: "sahil lavingia", purchase_state: "in_progress", offer_code: @offer_code)
      end

      it "sends the notification webhook" do
        @purchase.send_notification_webhook
        expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(@purchase.id, nil)
      end
    end

    describe "with gifting" do
      before do
        @product = create(:product, price_cents: 600, user: create(:user, notification_endpoint: "http://notification.com"))
        gifter_email = "gifter@foo.com"
        giftee_email = "giftee@foo.com"
        gift = create(:gift, gifter_email:, giftee_email:, link: @product)
        @gifter_purchase = create(:purchase, link: @product, seller: @product.user, price_cents: @product.price_cents,
                                             full_name: "sahil lavingia", email: gifter_email, purchase_state: "in_progress")
        gift.gifter_purchase = @gifter_purchase
        @gifter_purchase.is_gift_sender_purchase = true
        @gifter_purchase.save!
        @giftee_purchase = gift.giftee_purchase = create(:purchase, link: @product, seller: @product.user, email: giftee_email, price_cents: 0,
                                                                    stripe_transaction_id: nil, stripe_fingerprint: nil,
                                                                    is_gift_receiver_purchase: true, purchase_state: "in_progress")
        gift.mark_successful
        gift.save!
      end

      it "sends the notification webhook for giftee purchase" do
        @giftee_purchase.send_notification_webhook
        expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(@giftee_purchase.id, nil)
      end

      it "does not send the notification webhook for gifter purchase" do
        @gifter_purchase.send_notification_webhook
        expect(PostToPingEndpointsWorker).to_not have_enqueued_sidekiq_job(@product.user.id,
                                                                           @product.id,
                                                                           @gifter_purchase.email,
                                                                           @gifter_purchase.price_cents,
                                                                           @product.price_currency_type,
                                                                           false,
                                                                           nil,
                                                                           {},
                                                                           {},
                                                                           nil,
                                                                           nil,
                                                                           false,
                                                                           false,
                                                                           "sahil lavingia",
                                                                           @gifter_purchase.id)
      end
    end

    describe "recurring charge" do
      let(:product) do
        create(:membership_product, price_cents: 600, user: create(:user, notification_endpoint: "http://notification.com"))
      end
      let(:recurring_purchase) do
        create(:recurring_membership_purchase, link: product, seller: product.user, purchase_state: "in_progress", price_cents: product.price_cents)
      end

      it "does not send the notification webhook" do
        recurring_purchase.send_notification_webhook
        expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(recurring_purchase.id, nil)
      end
    end
  end

  describe "#send_notification_webhook_from_ui" do
    before do
      product = create(:product, user: create(:user, notification_endpoint: "http://notification.com"))
      gifter_email = "gifter@foo.com"
      giftee_email = "giftee@foo.com"
      gift = create(:gift, gifter_email:, giftee_email:, link: product)
      @gifter_purchase = create(:purchase, :gift_sender,
                                link: product, seller: product.user, price_cents: product.price_cents,
                                email: gifter_email, purchase_state: "in_progress", gift_given: gift)
      @giftee_purchase = create(:purchase, :gift_receiver,
                                link: product, seller: product.user, email: giftee_email, price_cents: 0,
                                stripe_transaction_id: nil, stripe_fingerprint: nil, gift_received: gift,
                                purchase_state: "in_progress")
      gift.mark_successful
      gift.save!
    end

    it "when called for the giftee purchase it sends the notification webhook for the giftee purchase" do
      @giftee_purchase.send_notification_webhook_from_ui

      expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(@giftee_purchase.id, nil)
      expect(PostToPingEndpointsWorker).to_not have_enqueued_sidekiq_job(@gifter_purchase.id, nil)
    end

    it "when called for the gifter purchase it sends the notification webhook for the giftee purchase" do
      @gifter_purchase.send_notification_webhook_from_ui

      expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(@giftee_purchase.id, nil)
      expect(PostToPingEndpointsWorker).to_not have_enqueued_sidekiq_job(@gifter_purchase.id, nil)
    end
  end

  describe "#send_refunded_notification_webhook" do
    it "enqueues the post to ping job for refunded notification" do
      purchase = create(:purchase)

      purchase.send(:send_refunded_notification_webhook)

      expect(PostToPingEndpointsWorker).to have_enqueued_sidekiq_job(purchase.id, nil, ResourceSubscription::REFUNDED_RESOURCE_NAME)
    end
  end
end
