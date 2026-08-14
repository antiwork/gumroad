# frozen_string_literal: true

require "spec_helper"

describe CustomerLowPriorityMailer do
  describe "blocked_purchase_resolved" do
    let(:purchase) { create(:purchase, purchase_state: "failed", email: "buyer@example.com") }

    it "tells the buyer the issue is fixed and they can retry, without naming internals" do
      mail = CustomerLowPriorityMailer.blocked_purchase_resolved(purchase.id)

      expect(mail.to).to eq(["buyer@example.com"])
      expect(mail.subject).to eq("Your payment issue has been resolved")
      expect(mail.body.encoded).to include("payment issue on our side")
      expect(mail.body.encoded).to include("You did nothing wrong")
      expect(mail.body.encoded).to include("try your purchase again")
      expect(mail.body.encoded).to include(purchase.link.name)
      # The layout's CSS legitimately says "block"; the copy must not say these.
      expect(mail.body.encoded).not_to match(/fraud|fingerprint|platform block|radar/i)
    end

    it "sends nothing to an invalid address" do
      purchase.update_columns(email: "not-an-email")

      mail = CustomerLowPriorityMailer.blocked_purchase_resolved(purchase.id)
      expect(mail.to).to be_nil
    end
  end

  describe "subscription_autocancelled" do
    context "memberships" do
      before do
        @product = create(:subscription_product, name: "fan club")
        @subscription = create(:subscription, link: @product)
        @purchase = create(:purchase, is_original_subscription_purchase: true, link: @product, subscription: @subscription)
      end

      it "notifies user of subscription cancellation" do
        mail = CustomerLowPriorityMailer.subscription_autocancelled(@subscription.id)
        expect(mail.subject).to eq "Your subscription has been canceled."
        expect(mail.body.encoded).to match("Your subscription to fan club has been automatically canceled due to multiple failed payments")
      end

      it "sets the correct SendGrid account with creator's mailer_level" do
        stub_const(
          "EMAIL_CREDENTIALS",
          {
            MailerInfo::EMAIL_PROVIDER_SENDGRID => {
              customers: {
                levels: {
                  level_1: {
                    address: SENDGRID_SMTP_ADDRESS,
                    username: "apiKey_for_level_1",
                    password: "sendgrid-api-secret",
                    domain: CUSTOMERS_MAIL_DOMAIN,
                  }
                }
              }
            }
          }
        )
        mail = CustomerLowPriorityMailer.subscription_autocancelled(@subscription.id)

        expect(mail.delivery_method.settings[:user_name]).to eq "apiKey_for_level_1"
        expect(mail.delivery_method.settings[:password]).to eq "sendgrid-api-secret"
      end
    end

    context "installment plans" do
      let(:installment_plan_purchase) { create(:installment_plan_purchase) }
      let(:subscription) { installment_plan_purchase.subscription }

      it "notifies user of installment plan pause" do
        mail = CustomerLowPriorityMailer.subscription_autocancelled(subscription.id)
        expect(mail.subject).to eq "Your installment plan has been paused."
        expect(mail.body.encoded).to include("your installment plan for #{subscription.link.name} has been paused")
      end
    end
  end

  describe "subscription_cancelled" do
    before do
      @product = create(:membership_product, name: "fan club", subscription_duration: "monthly")
    end

    it "confirms with user that they meant to cancel their subscription" do
      subscription = create(:subscription, link: @product)
      create(:purchase, is_original_subscription_purchase: true, link: @product, subscription:)
      mail = CustomerLowPriorityMailer.subscription_cancelled(subscription.id)
      expect(mail.body.encoded).to match(/You have canceled your subscription to fan club\. You will .* your billing cycle/)
    end
  end

  describe "subscription_cancelled_by_seller" do
    context "memberships" do
      before do
        @product = create(:membership_product, name: "fan club", subscription_duration: "monthly")
        @subscription = create(:subscription, link: @product)
        @purchase = create(:purchase, is_original_subscription_purchase: true, link: @product, subscription: @subscription)
      end

      it "notifies customer that seller cancelled their subscription" do
        mail = CustomerLowPriorityMailer.subscription_cancelled_by_seller(@subscription.id)
        expect(mail.subject).to eq "Your subscription has been canceled."
        expect(mail.body.encoded).to match(/Your subscription to fan club has been canceled by the creator\. You will .* your billing cycle/)
      end
    end

    context "installment plans" do
      let(:installment_plan_purchase) { create(:installment_plan_purchase) }
      let(:subscription) { installment_plan_purchase.subscription }

      it "notifies customer that seller cancelled their installment plan" do
        mail = CustomerLowPriorityMailer.subscription_cancelled_by_seller(subscription.id)
        expect(mail.subject).to eq "Your installment plan has been canceled."
        expect(mail.body.encoded).to match(/Your installment plan for #{subscription.link.name} has been canceled by the creator/)
      end
    end
  end

  describe "subscription_card_declined" do
    it "lets user know their card was declined" do
      subscription = create(:subscription, link: create(:product))
      create(:purchase, is_original_subscription_purchase: true, link: subscription.link, subscription:)
      mail = CustomerLowPriorityMailer.subscription_card_declined(subscription.id)
      expect(mail.subject).to eq "Your card was declined."
      expect(mail.body.encoded).to include subscription.link.name
      expect(mail.body.encoded).to include "/subscriptions/#{subscription.external_id}/manage?declined=true&amp;token=#{subscription.reload.token}"
    end

    it "asks a UPI subscriber to update their payment method" do
      upi_card = CreditCard.create!(
        charge_processor_id: StripeChargeProcessor.charge_processor_id,
        payment_method_type: "upi",
        stripe_customer_id: "cus_upi",
        processor_payment_method_id: "pm_upi",
        stripe_fingerprint: "pm_upi",
        visual: "UPI",
        card_type: CardType::UPI,
        card_country: Compliance::Countries::IND.alpha2,
        recurring_authorization_verified_at: Time.current,
        recurring_authorization_currency: Currency::INR,
        recurring_authorization_max_amount_cents: 100_000
      )
      subscription = create(:subscription, link: create(:product), credit_card: upi_card)
      create(:purchase, is_original_subscription_purchase: true, link: subscription.link, subscription:)

      mail = CustomerLowPriorityMailer.subscription_card_declined(subscription.id)

      expect(mail.subject).to eq "Your payment method needs attention."
      expect(mail.body.encoded).to include "saved UPI payment method"
      expect(mail.body.encoded).to include "update your payment method"
      expect(mail.body.encoded).not_to include "re-authorize or update your card"
    end
  end

  describe "subscription_indian_card_mandate_invalid" do
    it "asks the buyer to update the payment method without ending current access" do
      subscription = create(:subscription, link: create(:subscription_product))
      create(:membership_purchase, subscription:, link: subscription.link, is_original_subscription_purchase: true)

      mail = described_class.subscription_indian_card_mandate_invalid(subscription.id)

      expect(mail.subject).to eq("Update your payment method to keep automatic renewals active.")
      expect(mail.body.encoded).to include("paused automatic renewals")
      expect(mail.body.encoded).to include("did not retry the payment")
      expect(mail.body.encoded).to include("keep access while renewals are paused")
      expect(mail.body.encoded).to include("/subscriptions/#{subscription.external_id}/manage")
    end
  end

  describe "subscription_card_declined_warning" do
    it "reminds user their card was declined" do
      subscription = create(:subscription, link: create(:product))
      create(:purchase, is_original_subscription_purchase: true, link: subscription.link, subscription:)
      mail = CustomerLowPriorityMailer.subscription_card_declined_warning(subscription.id)
      expect(mail.subject).to eq "Your card was declined."
      expect(mail.body.encoded).to include subscription.link.name
      expect(mail.body.encoded).to include "This is a reminder"
      expect(mail.body.encoded).to include "/subscriptions/#{subscription.external_id}/manage?declined=true&amp;token=#{subscription.reload.token}"
    end

    it "reminds a UPI subscriber to update their payment method" do
      upi_card = CreditCard.create!(
        charge_processor_id: StripeChargeProcessor.charge_processor_id,
        payment_method_type: "upi",
        stripe_customer_id: "cus_upi_warning",
        processor_payment_method_id: "pm_upi_warning",
        stripe_fingerprint: "pm_upi_warning",
        visual: "UPI",
        card_type: CardType::UPI,
        card_country: Compliance::Countries::IND.alpha2,
        recurring_authorization_verified_at: Time.current,
        recurring_authorization_currency: Currency::INR,
        recurring_authorization_max_amount_cents: 100_000
      )
      subscription = create(:subscription, link: create(:product), credit_card: upi_card)
      create(:purchase, is_original_subscription_purchase: true, link: subscription.link, subscription:)

      mail = CustomerLowPriorityMailer.subscription_card_declined_warning(subscription.id)

      expect(mail.subject).to eq "Your payment method needs attention."
      expect(mail.body.encoded).to include "saved UPI payment method"
      expect(mail.body.encoded).to include "update your payment method"
      expect(mail.body.encoded).not_to include "update your card"
    end
  end

  describe "subscription_renewal_reminder" do
    context "memberships" do
      it "reminds the user they will be charged for their subscription soon", :vcr do
        purchase = create(:membership_purchase)
        subscription = purchase.subscription

        mail = CustomerLowPriorityMailer.subscription_renewal_reminder(subscription.id)

        expect(mail.subject).to eq "Upcoming automatic membership renewal"
        expect(mail.body.encoded).to include "This is a reminder that your membership to \"#{purchase.link.name}\" will automatically renew on"
        expect(mail.body.encoded).to include "You're paying"
        expect(mail.body.encoded).to include "Questions about your product?"
        expect(mail.reply_to).to eq [purchase.link.user.email]
      end

      it "shows the upcoming renewal price instead of the original signup price" do
        purchase = create(:membership_purchase)
        subscription = purchase.subscription
        allow(Subscription).to receive(:find).with(subscription.id).and_return(subscription)
        allow(subscription).to receive(:current_subscription_price_cents).and_return(5_00)
        allow(subscription).to receive(:original_purchase).and_return(purchase)
        allow(purchase).to receive(:format_price_in_currency).with(5_00).and_return("$5")
        allow(purchase).to receive(:formatted_total_price).and_return("$10")

        mail = CustomerLowPriorityMailer.subscription_renewal_reminder(subscription.id)

        expect(mail.body.encoded).to include "You're paying $5."
        expect(mail.body.encoded).not_to include "You're paying $10."
      end
    end

    context "installment plans" do
      let(:installment_plan_purchase) { create(:installment_plan_purchase) }
      let(:subscription) { installment_plan_purchase.subscription }

      it "reminds the user they will be charged for their installment payment soon" do
        mail = CustomerLowPriorityMailer.subscription_renewal_reminder(subscription.id)

        expect(mail.subject).to eq "Upcoming installment payment reminder"
        expect(mail.body.encoded).to include "This is a reminder that your next installment payment"
        expect(mail.reply_to).to eq [subscription.link.user.email]
      end
    end
  end

  describe "subscription_price_change_notification" do
    let(:purchase) { create(:membership_purchase, price_cents: 5_00) }
    let(:subscription) { purchase.subscription }
    let(:tier) { purchase.tier }
    let(:new_price) { purchase.displayed_price_cents + 4_99 }
    let(:effective_date) { 1.month.from_now.to_date }

    before do
      tier.update!(apply_price_changes_to_existing_memberships: true, subscription_price_change_effective_date: effective_date)
      tier.prices.find_by(recurrence: "monthly").update!(price_cents: new_price)
    end

    it "notifies the subscriber the price will be changing soon" do
      mail = CustomerLowPriorityMailer.subscription_price_change_notification(subscription_id: subscription.id, new_price:)
      expect(mail.subject).to eq "Important changes to your membership"
      expect(mail.body.encoded).to include "The price of your membership to \"#{purchase.link.name}\" is changing on #{effective_date.strftime("%B %e, %Y")}."
      expect(mail.body.encoded).to include "$5 a month"
      expect(mail.body.encoded).to include "$9.99 a month"
      expect(mail.body.encoded).to include subscription.end_time_of_subscription.strftime("%B %e, %Y")
      expect(mail.body.encoded).not_to include "plus taxes"
    end

    it "includes tax details if applicable" do
      purchase.update!(was_purchase_taxable: true)

      mail = CustomerLowPriorityMailer.subscription_price_change_notification(subscription_id: subscription.id, new_price:)
      expect(mail.body.encoded).to include "$5 a month (plus taxes)"
      expect(mail.body.encoded).to include "$9.99 a month (plus taxes)"
    end

    it "includes custom message if set" do
      tier.update!(subscription_price_change_message: "<p>hi!</p>")

      mail = CustomerLowPriorityMailer.subscription_price_change_notification(subscription_id: subscription.id, new_price:)
      expect(mail.body.encoded).to include "hi!"
      expect(mail.body.encoded).not_to include "The price of your membership"
    end

    it "uses the correct tense if effective date is in the past" do
      travel_to effective_date + 1.day
      mail = CustomerLowPriorityMailer.subscription_price_change_notification(subscription_id: subscription.id, new_price:)
      expect(mail.body.encoded).to include "The price of your membership to \"#{purchase.link.name}\" changed on #{effective_date.to_date.strftime("%B %e, %Y")}."
      expect(mail.body.encoded).to include "You will be charged the new price starting with your next billing period."
    end
  end

  describe "chargeback_notice_to_customer" do
    let(:seller) { create(:user) }

    context "for a dispute on Purchase" do
      let(:product) { create(:product, user: seller) }
      let!(:purchase) { create(:purchase, seller:, link: product) }
      let(:dispute) { create(:dispute_formalized, purchase:) }

      it "has the correct text" do
        mail = CustomerLowPriorityMailer.chargeback_notice_to_customer(dispute.id)

        expect(mail.subject).to eq "Regarding your recent dispute."
        expect(mail.body.encoded).to include "You recently filed a dispute for your purchase of "\
          "<a href=\"#{product.long_url}\">#{product.name}</a> for #{purchase.formatted_disputed_amount}. " \
          "A receipt was sent to #{purchase.email} — please check your Spam folder if you are unable to locate it."
        expect(mail.body.encoded).to include "If you filed this dispute because you didn't recognize \"Gumroad\" on your account statement, " \
          "you can contact your bank or PayPal to cancel the dispute."
      end
    end

    context "for a dispute on Charge" do
      let(:charge) do
        charge = create(:charge, seller:)
        charge.purchases << create(:purchase, seller:, link: create(:product, user: seller))
        charge.purchases << create(:purchase, seller:, link: create(:product, user: seller))
        charge.purchases << create(:purchase, seller:, link: create(:product, user: seller))
        charge
      end

      let(:dispute) { create(:dispute_formalized_on_charge, purchase: nil, charge:) }

      it "has the correct text" do
        mail = CustomerLowPriorityMailer.chargeback_notice_to_customer(dispute.id)

        expect(mail.subject).to eq "Regarding your recent dispute."
        expect(mail.body.encoded).to include "You recently filed a dispute for your purchase of "\
          "the following items for #{charge.formatted_disputed_amount}. " \
          "A receipt was sent to #{charge.customer_email} — please check your Spam folder if you are unable to locate it."
        expect(mail.body.encoded).to include "If you filed this dispute because you didn't recognize \"Gumroad\" on your account statement, " \
          "you can contact your bank or PayPal to cancel the dispute."
      end
    end
  end

  describe "sample_subscription_price_change_notification" do
    let(:effective_date) { 1.month.from_now.to_date }
    let(:product) { create(:membership_product) }
    let(:tier) { product.default_tier }

    it "sends the user a sample price change notification" do
      mail = CustomerLowPriorityMailer.sample_subscription_price_change_notification(user: product.user, tier:, effective_date:, recurrence: "yearly", new_price: 20_00)
      expect(mail.subject).to eq "Important changes to your membership"
      expect(mail.body.encoded).to include "The price of your membership to \"#{product.name}\" is changing on #{effective_date.strftime("%B %e, %Y")}."
      expect(mail.body.encoded).to include "$16 a year"
      expect(mail.body.encoded).to include "$20 a year"
      expect(mail.body.encoded).to include (effective_date + 4.days).to_date.strftime("%B %e, %Y")
      expect(mail.body.encoded).not_to include "plus taxes"
    end

    it "includes a custom message, if present" do
      mail = CustomerLowPriorityMailer.sample_subscription_price_change_notification(user: product.user, tier:, effective_date:, recurrence: "yearly", new_price: 20_00, custom_message: "<p>hi!</p>")
      expect(mail.body.encoded).to include "hi!"
      expect(mail.body.encoded).not_to include "The price of your membership"
    end

    it "includes the charge count for a fixed-length membership" do
      product.update!(duration_in_months: 12)
      tier.reload
      mail = CustomerLowPriorityMailer.sample_subscription_price_change_notification(user: product.user, tier:, effective_date:, recurrence: "monthly", new_price: 20_00)
      expect(mail.body.encoded).to include "$16 a month x 12"
      expect(mail.body.encoded).to include "$20 a month x 12"
    end
  end

  describe "subscription_charge_failed" do
    context "memberships" do
      it "notifies the customer their charge failed" do
        subscription = create(:subscription, link: create(:product))
        create(:purchase, is_original_subscription_purchase: true, link: subscription.link, subscription:)
        mail = CustomerLowPriorityMailer.subscription_charge_failed(subscription.id)
        expect(mail.subject).to eq "Your recurring charge failed."
        expect(mail.body.encoded).to include subscription.link.name
      end
    end

    context "installment plans" do
      let(:installment_plan_purchase) { create(:installment_plan_purchase) }
      let(:subscription) { installment_plan_purchase.subscription }

      it "notifies the customer their installment payment failed" do
        mail = CustomerLowPriorityMailer.subscription_charge_failed(subscription.id)
        expect(mail.subject).to eq "Your installment payment failed."
        expect(mail.body.encoded).to include subscription.link.name
      end
    end
  end

  describe "subscription_charge_blocked_location" do
    context "memberships" do
      it "explains the location block without blaming the card, and links to manage subscription" do
        subscription = create(:subscription, link: create(:product))
        create(:purchase, is_original_subscription_purchase: true, link: subscription.link, subscription:)

        mail = CustomerLowPriorityMailer.subscription_charge_blocked_location(subscription.id)

        expect(mail.subject).to eq "Your membership could not be renewed."
        expect(mail.body.encoded).to include subscription.link.name
        expect(mail.body.encoded).to include "United States sanctions"
        expect(mail.body.encoded).to include "no charge was attempted"
        expect(mail.body.encoded).to include "nothing wrong with your card"
        expect(mail.body.encoded).to include "/manage"
      end

      it "does not tell the subscriber to update or re-authorize their card" do
        subscription = create(:subscription, link: create(:product))
        create(:purchase, is_original_subscription_purchase: true, link: subscription.link, subscription:)

        body = CustomerLowPriorityMailer.subscription_charge_blocked_location(subscription.id).body.encoded

        expect(body).to_not include "attempted to charge your card"
        expect(body).to_not include "re-authorize"
        expect(body).to_not include "update your card"
      end

      it "links to manage subscription with the token that is valid after sending" do
        subscription = create(:subscription, link: create(:product))
        create(:purchase, is_original_subscription_purchase: true, link: subscription.link, subscription:)

        body = CustomerLowPriorityMailer.subscription_charge_blocked_location(subscription.id).body.encoded

        expect(body).to include "token=#{subscription.reload.token}"
      end

      it "marks the manage link as coming from a failure email so the retry it invites does not re-send it" do
        subscription = create(:subscription, link: create(:product))
        create(:purchase, is_original_subscription_purchase: true, link: subscription.link, subscription:)

        body = CustomerLowPriorityMailer.subscription_charge_blocked_location(subscription.id).body.encoded

        expect(body).to include "declined=true"
      end
    end

    context "installment plans" do
      let(:installment_plan_purchase) { create(:installment_plan_purchase) }
      let(:subscription) { installment_plan_purchase.subscription }

      it "uses installment-plan wording" do
        mail = CustomerLowPriorityMailer.subscription_charge_blocked_location(subscription.id)

        expect(mail.subject).to eq "Your installment payment could not be processed."
        expect(mail.body.encoded).to include "installment plan"
      end

      it "says the plan will be paused rather than canceled" do
        body = CustomerLowPriorityMailer.subscription_charge_blocked_location(subscription.id).body.encoded

        expect(body).to include "will be paused"
        expect(body).to_not include "will be canceled"
      end
    end
  end

  describe "subscription_ended" do
    context "memberships" do
      before do
        @product = create(:membership_product, name: "fan club", subscription_duration: "monthly", duration_in_months: 6)
      end

      it "confirms with user that they meant to cancel their subscription" do
        subscription = create(:subscription, link: @product, charge_occurrence_count: 6)
        create(:purchase, is_original_subscription_purchase: true, link: @product, subscription:)
        mail = CustomerLowPriorityMailer.subscription_ended(subscription.id)
        expect(mail.subject).to eq "Your subscription has ended."
        expect(mail.body.encoded).to match(/subscription to fan club has ended. You will no longer be charged/)
      end

      it "has the correct text for a membership ending" do
        @product.block_access_after_membership_cancellation = true
        @product.save
        subscription = create(:subscription, link: @product, charge_occurrence_count: 6)
        create(:purchase, is_original_subscription_purchase: true, link: @product, subscription:)
        mail = CustomerLowPriorityMailer.subscription_ended(subscription.id)
        expect(mail.body.encoded).to match(/subscription to fan club has ended. You will no longer be charged/)
      end
    end

    context "installment plans" do
      let(:installment_plan_purchase) { create(:installment_plan_purchase) }
      let(:subscription) { installment_plan_purchase.subscription }

      it "notifies the customer their installment plan has been paid in full" do
        mail = CustomerLowPriorityMailer.subscription_ended(subscription.id)
        expect(mail.subject).to eq "Your installment plan has been paid in full."
        expect(mail.body.encoded).to include "You have completed all your installment payments for #{subscription.link.name}"
      end
    end
  end

  describe "#subscription_early_fraud_warning_notification" do
    let(:purchase) do
      create(
        :membership_purchase,
        email: "buyer@example.com",
        price_cents: 500,
        created_at: Date.parse("Nov 20, 2023")
      )
    end

    before do
      purchase.subscription.user.update!(email: "buyer@example.com")
    end

    it "notifies the buyer" do
      mail = CustomerLowPriorityMailer.subscription_early_fraud_warning_notification(purchase.id)

      expect(mail.subject).to eq "Regarding your recent purchase reported as fraud"
      expect(mail.to).to eq ["buyer@example.com"]
      expect(mail.reply_to).to eq [purchase.link.user.email]

      expect(mail.body.encoded).to include "You recently reported as fraud the transaction for your purchase"
      expect(mail.body.encoded).to include "A receipt was sent to buyer@example.com — please check your Spam folder if you are unable to locate it"
      expect(mail.body.encoded).to include "Manage membership"
    end
  end

  describe "#subscription_giftee_added_card", vcr: true do
    let(:gift) { create(:gift, gift_note: "Gift note", giftee_email: "giftee@example.com") }
    let(:product) { create(:membership_product) }
    let(:subscription) { create(:subscription, link: product, user: nil, credit_card: create(:credit_card)) }
    let!(:original_purchase) { create(:membership_purchase, gift_given: gift, is_gift_sender_purchase: true, is_original_subscription_purchase: true, subscription:) }
    let!(:purchase) { create(:membership_purchase, gift_received: gift, is_gift_receiver_purchase: true, is_original_subscription_purchase: false, subscription:) }

    it "notifies the giftee" do
      mail = CustomerLowPriorityMailer.subscription_giftee_added_card(subscription.id)

      expect(mail.subject).to eq "You've added a payment method to your membership"
      expect(mail.to).to eq ["giftee@example.com"]

      expect(mail.body.sanitized).to include product.name
      expect(mail.body.sanitized).to include "You will be charged once a month. If you would like to manage your membership you can visit"
      expect(mail.body.sanitized).to include "First payment #{subscription.formatted_end_time_of_subscription}"
      expect(mail.body.sanitized).to include "Payment method VISA *4242"
    end

    context "when the subscription's credit card is missing" do
      let(:subscription) { create(:subscription, link: product, user: nil, credit_card: nil) }

      it "logs the skip and does not deliver the email" do
        expect(Rails.logger).to receive(:warn).with(
          "[CustomerLowPriorityMailer] Skipping subscription email delivery because @subject is nil; action=subscription_giftee_added_card; subscription_id=#{subscription.id}"
        )

        expect do
          CustomerLowPriorityMailer.subscription_giftee_added_card(subscription.id).deliver_now
        end.not_to change(ActionMailer::Base.deliveries, :count)
      end
    end
  end

  describe "order_shipped" do
    before do
      @seller = create(:user, name: "Edgar")
      @product = create(:physical_product, user: @seller)
      @purchase = create(:physical_purchase, link: @product)
    end

    describe "without tracking" do
      before do
        @shipment = create(:shipment, purchase: @purchase, ship_state: :shipped)
      end

      it "mails to and reply-to the correct email" do
        mail = CustomerLowPriorityMailer.order_shipped(@shipment.id)
        expect(mail.to).to eq [@purchase.email]
        expect(mail.reply_to).to eq [@product.user.email]
      end

      it "has correct subject" do
        mail = CustomerLowPriorityMailer.order_shipped(@shipment.id)
        expect(mail.subject).to eq "Your order has shipped!"
      end

      it "has the link name in the body" do
        mail = CustomerLowPriorityMailer.order_shipped(@shipment.id)
        expect(mail.body.encoded).to include @product.name
      end
    end

    describe "with tracking" do
      before do
        @shipment = create(:shipment, purchase: @purchase, ship_state: :shipped, tracking_url: "https://tools.usps.com/go/TrackConfirmAction?qtc_tLabels1=9400111899223197428490")
      end

      it "mails to and reply-to the correct email" do
        mail = CustomerLowPriorityMailer.order_shipped(@shipment.id)
        expect(mail.to).to eq [@purchase.email]
        expect(mail.reply_to).to eq [@product.user.email]
      end

      it "has correct subject" do
        mail = CustomerLowPriorityMailer.order_shipped(@shipment.id)
        expect(mail.subject).to eq "Your order has shipped!"
      end

      it "has the correct link name in the body" do
        mail = CustomerLowPriorityMailer.order_shipped(@shipment.id)
        expect(mail.body.encoded).to include @product.name
      end

      it "has the tracking url in the body" do
        mail = CustomerLowPriorityMailer.order_shipped(@shipment.id)
        expect(mail.body.encoded).to include @shipment.tracking_url
      end

      it "uses the trusted label only for a verified carrier tracking link" do
        mail = CustomerLowPriorityMailer.order_shipped(@shipment.id)
        expect(mail.body.decoded).to include "Track your package"
        expect(mail.body.decoded).not_to include "Seller-provided tracking link"
      end

      it "labels seller-provided tracking links with the destination host" do
        @shipment.update!(tracking_url: "https://www.google.com/track")

        mail = CustomerLowPriorityMailer.order_shipped(@shipment.id)
        expect(mail.body.decoded).to include "Seller-provided tracking link"
        expect(mail.body.decoded).to include "Destination: www.google.com"
      end

      it "labels an arbitrary page on a carrier host as seller-provided" do
        @shipment.update!(tracking_url: "https://tools.usps.com/not-a-tracking-form")

        mail = CustomerLowPriorityMailer.order_shipped(@shipment.id)
        expect(mail.body.decoded).to include "Seller-provided tracking link"
        expect(mail.body.decoded).to include "Destination: tools.usps.com"
      end

      it "does not render legacy invalid tracking links" do
        @shipment.update_column(:tracking_url, "1Z999AA10123456784")

        mail = CustomerLowPriorityMailer.order_shipped(@shipment.id)
        expect(mail.body.decoded).to include "has been shipped and should arrive soon"
        expect(mail.body.decoded).not_to include "Track your package"
        expect(mail.body.decoded).not_to include "1Z999AA10123456784"
      end
    end
  end

  describe "free_trial_expiring_soon" do
    it "notifies the customer that their free trial is expiring soon" do
      purchase = create(:free_trial_membership_purchase)

      mail = CustomerLowPriorityMailer.free_trial_expiring_soon(purchase.subscription_id)

      expect(mail.subject).to eq "Your free trial is ending soon"
      expect(mail.body.encoded).to include "Your free trial to #{purchase.link.name} is expiring on #{purchase.subscription.free_trial_end_date_formatted}, at which point you will be charged. If you wish to cancel your membership, you can do so at any time"
      expect(mail.body.encoded).to include "/subscriptions/#{purchase.subscription.external_id}/manage?token=#{purchase.subscription.reload.token}"
    end
  end

  describe "already_subscribed_checkout_attempt" do
    it "includes a tokenized link to manage the existing subscription" do
      purchase = create(:membership_purchase)
      subscription = purchase.subscription

      mail = CustomerLowPriorityMailer.already_subscribed_checkout_attempt(subscription.id)

      expect(mail.subject).to eq "Someone tried to purchase a membership you already have"
      expect(mail.body.encoded).to include "manage your subscription here"
      expect(mail.body.encoded).to include "/subscriptions/#{subscription.external_id}/manage?token=#{subscription.reload.token}"
    end

    it "reuses a still-valid token across repeated deliveries so earlier links keep working" do
      purchase = create(:membership_purchase)
      subscription = purchase.subscription

      first_body = CustomerLowPriorityMailer.already_subscribed_checkout_attempt(subscription.id).body.encoded
      first_token = subscription.reload.token

      second_body = CustomerLowPriorityMailer.already_subscribed_checkout_attempt(subscription.id).body.encoded

      expect(subscription.reload.token).to eq first_token
      expect(first_body).to include "token=#{first_token}"
      expect(second_body).to include "token=#{first_token}"
    end

    it "mints a new token when the existing one has expired" do
      purchase = create(:membership_purchase)
      subscription = purchase.subscription
      subscription.update!(token: "expired-token", token_expires_at: 1.minute.ago)

      body = CustomerLowPriorityMailer.already_subscribed_checkout_attempt(subscription.id).body.encoded

      new_token = subscription.reload.token
      expect(new_token).not_to eq "expired-token"
      expect(subscription.token_expires_at).to be > Time.current
      expect(body).to include "token=#{new_token}"
    end
  end

  describe "expiring credit card membership", :vcr do
    it "notifies the customer that their credit card is expiring" do
      expiring_cc_user = create(:user, credit_card: create(:credit_card))
      subscription = create(:subscription, user: expiring_cc_user, credit_card_id: expiring_cc_user.credit_card_id)
      create(:purchase, is_original_subscription_purchase: true, subscription:)
      mail = CustomerLowPriorityMailer.credit_card_expiring_membership(subscription.id)

      expect(mail.subject).to eq "Payment method for #{subscription.link.name} is about to expire"
      expect(mail.body.encoded).to include "To continue your <strong>#{subscription.link.name}</strong> subscription, please update your card information."
    end
  end

  describe "preorder_card_declined" do
    it "notifies the customer that the preorder charge was declined" do
      product = create(:product)
      preorder_link = create(:preorder_link, link: product)
      preorder = preorder_link.build_preorder(create(:preorder_authorization_purchase, link: product))
      preorder.save!
      mail = CustomerLowPriorityMailer.preorder_card_declined(preorder.id)
      expect(mail.subject).to eq "Could not charge your credit card for #{product.name}"
      expect(mail.body.encoded).to include preorder.link.name
      expect(mail.body.encoded).to have_link("here", href: preorder.link.long_url)
    end
  end

  describe "#bundle_content_updated" do
    let(:purchase) { create(:purchase) }

    before { purchase.seller.update!(name: "Seller") }

    it "notifies the customer that the bundle content has been updated" do
      mail = CustomerLowPriorityMailer.bundle_content_updated(purchase.id)
      expect(mail.subject).to eq "Seller just added content to The Works of Edgar Gumstein"
      expect(mail.body.encoded).to have_text("Seller just added content to The Works of Edgar Gumstein")
      expect(mail.body.encoded).to have_text("Get excited! Seller just added new content to The Works of Edgar Gumstein. You can access it by visiting your library or clicking the button below.")
      expect(mail.body.encoded).to have_link("View content", href: library_url({ bundles: purchase.link.external_id }))
    end
  end

  describe "#purchase_review_reminder" do
    let(:purchase) { create(:purchase, full_name: "Buyer") }

    context "purchase does not have review" do
      it "sends an email" do
        mail = CustomerLowPriorityMailer.purchase_review_reminder(purchase.id)
        expect(mail.subject).to eq("Liked The Works of Edgar Gumstein? Give it a review!")
        expect(mail.body.encoded).to have_text("Liked The Works of Edgar Gumstein? Give it a review!")
        expect(mail.body.encoded).to have_text("Hi Buyer,")
        expect(mail.body.encoded).to have_text("Hope you're getting great value from #{purchase.link.name}.")
        expect(mail.body.encoded).to have_text("We'd love to hear your thoughts on it. When you have a moment, could you drop us a quick review?")
        expect(mail.body.encoded).to have_text("Thank you for your contribution!")
        expect(mail.body.encoded).to have_link("Leave a review", href: purchase.link.long_url)
        expect(mail.body.encoded).to have_link("Unsubscribe")
      end

      it "gives a guest buyer a purchase-scoped unsubscribe link that resolves without a session" do
        body = CustomerLowPriorityMailer.purchase_review_reminder(purchase.id).body.encoded

        expect(purchase.purchaser).to be_nil
        token = body[%r{/purchases/([^/]+)/unsubscribe}, 1]
        expect(token).to be_present
        expect(Purchase.find_by_secure_external_id(CGI.unescape(token), scope: "unsubscribe")).to eq(purchase)
      end

      context "purchase does not have name" do
        before { purchase.update!(full_name: nil) }

        context "purchaser's account has name" do
          before { purchase.update!(purchaser: create(:user, name: "Purchaser")) }

          it "uses the purchaser's account name" do
            expect(CustomerLowPriorityMailer.purchase_review_reminder(purchase.id).body.encoded).to have_text("Hi Purchaser,")
          end
        end

        context "purchaser's account does not has name" do
          it "excludes the name" do
            expect(CustomerLowPriorityMailer.purchase_review_reminder(purchase.id).body.encoded).to have_text("Hi,")
          end
        end
      end

      context "purchase has a UrlRedirect" do
        before { purchase.create_url_redirect! }

        it "uses the download page URL" do
          mail = CustomerLowPriorityMailer.purchase_review_reminder(purchase.id)
          expect(mail.body.encoded).to have_link("Leave a review", href: purchase.url_redirect.download_page_url)
        end
      end

      context "purchaser has an account" do
        before { purchase.update!(purchaser: create(:user, name: "Purchaser", email: purchase.email)) }

        it "includes a token-scoped unsubscribe link that resolves without a session" do
          body = CustomerLowPriorityMailer.purchase_review_reminder(purchase.id).body.encoded

          # Tokens are non-deterministic (AES-GCM, random IV), so assert on what the emitted
          # token resolves to rather than comparing against a freshly minted one.
          token = body[%r{/users/unsubscribe_review_reminders/([A-Za-z0-9_-]+)}, 1]
          expect(token).to be_present
          expect(User.find_by_secure_external_id(token, scope: Users::ReviewRemindersController::TOKEN_SCOPE)).to eq(purchase.purchaser)
        end

        it "no longer points at the login-gated route" do
          body = CustomerLowPriorityMailer.purchase_review_reminder(purchase.id).body.encoded

          expect(body).to have_link("Unsubscribe")
          expect(body).not_to have_link("Unsubscribe", href: user_unsubscribe_review_reminders_url)
        end
      end

      context "purchaser was reassigned but the purchase email still points at the previous recipient" do
        before do
          purchase.update!(purchaser: create(:user, email: "new-owner@example.com"))
          purchase.update_column(:email, "previous-recipient@example.com")
        end

        it "falls back to the session-gated route so the recipient cannot opt the purchaser out unauthenticated" do
          mail = CustomerLowPriorityMailer.purchase_review_reminder(purchase.id)

          expect(mail.to).to eq(["previous-recipient@example.com"])
          expect(mail.body.encoded).not_to match(%r{/users/unsubscribe_review_reminders/})
          expect(mail.body.encoded).to have_link("Unsubscribe", href: user_unsubscribe_review_reminders_url)
        end
      end
    end

    context "purchase has review" do
      before { purchase.create_product_review }

      it "does not send an email" do
        expect do
          CustomerLowPriorityMailer.purchase_review_reminder(purchase.id)
        end.to_not change { ActionMailer::Base.deliveries.count }
      end
    end

    context "purchaser opted out of review reminders" do
      before { purchase.update!(purchaser: create(:user, opted_out_of_review_reminders: true)) }

      it "does not send an email" do
        expect do
          CustomerLowPriorityMailer.purchase_review_reminder(purchase.id)
        end.to_not change { ActionMailer::Base.deliveries.count }
      end
    end

    context "buyer unsubscribed from the seller" do
      before { purchase.update!(can_contact: false) }

      it "does not send an email" do
        expect do
          CustomerLowPriorityMailer.purchase_review_reminder(purchase.id).deliver_now
        end.to_not change { ActionMailer::Base.deliveries.count }
      end
    end

    context "bundle purchase" do
      before { purchase.update!(is_bundle_purchase: true) }

      shared_examples "links to the product page with the purchase credentials" do
        it "links to the bundle's product page with the purchase credentials for the review form" do
          mail = CustomerLowPriorityMailer.purchase_review_reminder(purchase.id)
          expected_url = "#{purchase.link.long_url}?#{{ purchase_id: purchase.external_id, purchase_email_digest: purchase.email_digest }.to_query}"
          expect(mail.body.encoded).to have_link("Leave a review", href: expected_url)
        end
      end

      context "when the buyer has an account" do
        before { purchase.update!(purchaser: create(:user)) }

        include_examples "links to the product page with the purchase credentials"
      end

      context "when the purchase is a guest purchase" do
        include_examples "links to the product page with the purchase credentials"
      end
    end

    context "bundle product purchase" do
      before { purchase.update!(is_bundle_product_purchase: true) }

      it "does not send an email" do
        expect do
          CustomerLowPriorityMailer.purchase_review_reminder(purchase.id)
        end.to_not change { ActionMailer::Base.deliveries.count }
      end
    end
  end

  describe "#order_review_reminder" do
    let(:purchase) { create(:purchase, full_name: "Buyer") }
    let(:order) { create(:order, purchases: [purchase]) }

    it "sends an email" do
      mail = CustomerLowPriorityMailer.order_review_reminder(order.id)
      expect(mail.subject).to eq("Liked your order? Leave some reviews!")
      expect(mail.body.encoded).to have_text("Liked your order? Leave some reviews!")
      expect(mail.body.encoded).to have_text("Hi Buyer,")
      expect(mail.body.encoded).to have_text("Hope you're getting great value from your order.")
      expect(mail.body.encoded).to have_text("We'd love to hear your thoughts on it. When you have a moment, could you drop us some reviews?")
      expect(mail.body.encoded).to have_text("Thank you for your contribution!")
      expect(mail.body.encoded).to have_link("Leave reviews", href: reviews_url)
      unsubscribe_token = mail.body.encoded[%r{/users/unsubscribe_review_reminders/([A-Za-z0-9_-]+)}, 1]
      expect(User.find_by_secure_external_id(unsubscribe_token, scope: Users::ReviewRemindersController::TOKEN_SCOPE)).to eq(order.purchaser)
    end

    context "order has no purchaser account" do
      it "falls back to a purchase-scoped unsubscribe link" do
        order.update!(purchaser: nil)

        body = CustomerLowPriorityMailer.order_review_reminder(order.id).body.encoded

        token = body[%r{/purchases/([^/]+)/unsubscribe}, 1]
        expect(token).to be_present
        expect(Purchase.find_by_secure_external_id(CGI.unescape(token), scope: "unsubscribe")).to eq(purchase)
      end

      it "mints the token from a purchase the email is about, skipping excluded ones" do
        # `excluded` is first in the order, so it is what `order.purchases.first` returns —
        # the row the token used to come from even though it gets no reminder.
        excluded = create(:purchase, full_name: "Buyer", can_contact: false)
        multi_seller_order = create(:order, purchaser: nil, purchases: [excluded, purchase])
        expect(multi_seller_order.purchases.first).to eq(excluded)

        body = CustomerLowPriorityMailer.order_review_reminder(multi_seller_order.id).body.encoded

        token = body[%r{/purchases/([^/]+)/unsubscribe}, 1]
        expect(Purchase.find_by_secure_external_id(CGI.unescape(token), scope: "unsubscribe")).to eq(purchase)
      end

      it "addresses the buyer of the purchase it is about, not an excluded first row" do
        excluded = create(:purchase, full_name: "Excluded Buyer", email: "excluded@example.com", can_contact: false)
        mixed_order = create(:order, purchaser: nil, purchases: [excluded, purchase])

        mail = CustomerLowPriorityMailer.order_review_reminder(mixed_order.id)

        expect(mail.to).to eq([purchase.email])
        expect(mail.to).not_to include(excluded.email)
        expect(mail.body.encoded).to have_text("Hi Buyer,")
      end

      it "does not send when no purchase in the order is still eligible" do
        order.update!(purchaser: nil)
        purchase.update!(can_contact: false)

        expect do
          CustomerLowPriorityMailer.order_review_reminder(order.id).deliver_now
        end.to_not change { ActionMailer::Base.deliveries.count }
      end
    end

    context "purchase does not have name" do
      before { purchase.update!(full_name: nil) }

      context "purchaser's account has name" do
        before { order.update!(purchaser: create(:user, name: "Purchaser")) }

        it "uses the purchaser's account name" do
          expect(CustomerLowPriorityMailer.order_review_reminder(order.id).body.encoded).to have_text("Hi Purchaser,")
        end
      end

      context "purchaser's account does not has name" do
        it "excludes the name" do
          expect(CustomerLowPriorityMailer.order_review_reminder(order.id).body.encoded).to have_text("Hi,")
        end
      end
    end

    context "purchaser opted out of review reminders" do
      before { purchase.update!(purchaser: create(:user, opted_out_of_review_reminders: true)) }

      it "does not send an email" do
        expect do
          CustomerLowPriorityMailer.order_review_reminder(order.id)
        end.to_not change { ActionMailer::Base.deliveries.count }
      end
    end
  end

  describe "#wishlist_updated" do
    let(:wishlist) { create(:wishlist, user: create(:user, name: "Wishlist Creator")) }
    let!(:wishlist_product) { create(:wishlist_product, wishlist:) }
    let(:wishlist_follower) { create(:wishlist_follower, wishlist:) }

    it "sends an email" do
      mail = CustomerLowPriorityMailer.wishlist_updated(wishlist_follower.id, 1)
      expect(mail.subject).to eq("Wishlist Creator recently added a new product to their wishlist!")
      expect(mail.body.encoded).to have_text("Wishlist Creator recently added a new product to their wishlist!")
      expect(mail.body.encoded).to have_image(src: wishlist_product.product.for_email_thumbnail_url)
      expect(mail.body.encoded).to have_link(wishlist.name, href: wishlist_url(wishlist.url_slug, host: wishlist.user.subdomain_with_protocol))
      expect(mail.body.encoded).to have_link("View content", href: wishlist_url(wishlist.url_slug, host: wishlist.user.subdomain_with_protocol))
      expect(mail.body.encoded).to have_link("Unsubscribe", href: unsubscribe_wishlist_followers_url(wishlist.url_slug, follower_id: wishlist_follower.external_id))
    end

    context "when the follower has just unsubscribed" do
      before { wishlist_follower.mark_deleted! }

      it "does not send an email" do
        expect do
          CustomerLowPriorityMailer.wishlist_updated(wishlist_follower.id, 1)
        end.to_not change { ActionMailer::Base.deliveries.count }
      end
    end
  end

  describe "subscription_product_deleted" do
    context "memberships" do
      let(:purchase) { create(:membership_purchase) }
      let(:subscription) { purchase.subscription }
      let(:product) { subscription.link }

      it "notifies the customer their subscription has been canceled" do
        mail = CustomerLowPriorityMailer.subscription_product_deleted(subscription.id)
        expect(mail.subject).to eq "Your subscription has been canceled."
        expect(mail.body.encoded).to include "Your subscription to #{product.name} has been canceled"
        expect(mail.body.encoded).to include "due to the creator deleting the product"
      end
    end

    context "installment plans" do
      let(:installment_plan_purchase) { create(:installment_plan_purchase) }
      let(:subscription) { installment_plan_purchase.subscription }
      let(:product) { subscription.link }

      it "notifies the customer their installment plan has been canceled" do
        mail = CustomerLowPriorityMailer.subscription_product_deleted(subscription.id)
        expect(mail.subject).to eq "Your installment plan has been canceled."
        expect(mail.body.encoded).to include "Your installment plan for #{product.name} has been canceled"
        expect(mail.body.encoded).to include "due to the creator deleting the product"
      end
    end
  end

  describe "deposit" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }
    let(:payment) { create(:payment_completed, user: seller) }

    context "when the payout period has only Stripe Connect revenue" do
      before do
        allow_any_instance_of(User).to receive(:paypal_revenue_by_product_for_duration).and_return({})
        allow_any_instance_of(User).to receive(:stripe_connect_revenue_by_product_for_duration).and_return({ product.id => 1_000 })
      end

      it "renders the Stripe Connect revenue without raising when there is no Gumroad or PayPal revenue" do
        expect(payment.revenue_by_link).to be_blank

        mail = CustomerLowPriorityMailer.deposit(payment.id)

        expect(mail.subject).to eq "It's pay day!"
        expect(mail.body.encoded).to include product.name
        expect(mail.body.encoded).to include Money.new(1_000, "USD").format(symbol: true)
      end
    end
  end
end
