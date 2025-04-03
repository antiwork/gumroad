# frozen_string_literal: true

require "spec_helper"

describe Subscription::PingNotification do
  describe "#payload_for_ping_notification" do
    let(:purchase) { create(:membership_purchase) }
    let(:subscription) { purchase.subscription }

    it "contains subscription details" do
      params = subscription.payload_for_ping_notification(resource_name: ResourceSubscription::SALE_RESOURCE_NAME)

      expect(params.keys).to match_array [:subscription_id, :product_id, :product_name,
                                          :user_id, :user_email, :purchase_ids, :created_at,
                                          :charge_occurrence_count, :recurrence,
                                          :free_trial_ends_at, :resource_name]
    end

    it "contains custom fields if present in original purchase" do
      create(:purchase_custom_field, purchase:, name: "foo", value: "bar")

      payload = subscription.payload_for_ping_notification(resource_name: ResourceSubscription::SALE_RESOURCE_NAME)

      expect(payload[:resource_name]).to eq ResourceSubscription::SALE_RESOURCE_NAME
      expect(payload[:custom_fields]["foo"]).to eq "bar"
    end

    it "contains license_key if product has licensing enabled" do
      product = create(:membership_product, is_licensed: true)
      subscription = create(:subscription, link: product)
      purchase = create(:membership_purchase, subscription:, link: product)
      license = create(:license, link: product, purchase:)

      payload = subscription.payload_for_ping_notification(resource_name: ResourceSubscription::CANCELLED_RESOURCE_NAME)

      expect(payload[:license_key]).to eq license.serial
    end

    context "cancellation event" do
      it "contains the subscription cancellation details if the input resource_name is 'cancellation'" do
        cancelled_at_ts = Time.current
        subscription = create(:subscription, cancelled_at: cancelled_at_ts)
        subscription.purchases << create(:membership_purchase, subscription:) << create(:purchase)
        params = subscription.payload_for_ping_notification(resource_name: ResourceSubscription::CANCELLED_RESOURCE_NAME)

        expect(params[:resource_name]).to eq(ResourceSubscription::CANCELLED_RESOURCE_NAME)
        expect(params[:cancelled]).to be(true)
        expect(params[:cancelled_at]).to eq(cancelled_at_ts.as_json)
      end

      it "contains the details of who cancelled the subscription - admin/buyer/seller/payment failures" do
        cancellation_requested_at = 1.hour.ago
        cancelled_at_ts = Time.current
        subscription = create(:subscription, cancelled_at: cancelled_at_ts, user_requested_cancellation_at: cancellation_requested_at)
        subscription.purchases << create(:membership_purchase, subscription:) << create(:purchase)
        params = subscription.payload_for_ping_notification(resource_name: ResourceSubscription::CANCELLED_RESOURCE_NAME)

        expect(params[:cancelled]).to be(true)
        expect(params[:cancelled_at]).to eq(cancelled_at_ts.as_json)
        expect(params[:cancelled_by_seller]).to eq(true)
        expect(params).not_to have_key(:cancelled_by_buyer)
        expect(params).not_to have_key(:cancelled_by_admin)

        subscription.cancelled_by_buyer = true
        subscription.save!
        params = subscription.reload.payload_for_ping_notification(resource_name: ResourceSubscription::CANCELLED_RESOURCE_NAME)
        expect(params[:cancelled_by_buyer]).to eq(true)
        expect(params).not_to have_key(:cancelled_by_admin)
        expect(params).not_to have_key(:cancelled_by_seller)

        subscription.cancelled_by_admin = true
        subscription.save!
        params = subscription.reload.payload_for_ping_notification(resource_name: ResourceSubscription::CANCELLED_RESOURCE_NAME)
        expect(params[:cancelled_by_admin]).to eq(true)
        expect(params).not_to have_key(:cancelled_by_seller)
        expect(params).not_to have_key(:cancelled_by_buyer)

        subscription.cancelled_at = nil
        subscription.failed_at = Time.current
        subscription.save!
        params = subscription.reload.payload_for_ping_notification(resource_name: ResourceSubscription::CANCELLED_RESOURCE_NAME)
        expect(params[:cancelled_due_to_payment_failures]).to eq(true)
        expect(params).not_to have_key(:cancelled_by_seller)
        expect(params).not_to have_key(:cancelled_by_buyer)
        expect(params).not_to have_key(:cancelled_by_admin)
      end

      it "contains subscribing user's id and email when user is present, else contains subscribing email for logged out purchases" do
        subscription = create(:subscription, cancelled_at: Time.current)
        original_purchase_email = "orig@gum.co"
        subscription.purchases << create(:purchase, is_original_subscription_purchase: true, email: original_purchase_email) << create(:purchase)
        params = subscription.payload_for_ping_notification(resource_name: ResourceSubscription::CANCELLED_RESOURCE_NAME)

        expect(params[:resource_name]).to eq(ResourceSubscription::CANCELLED_RESOURCE_NAME)
        expect(params[:user_id]).to eq(subscription.user.external_id)
        expect(params[:user_email]).to eq(subscription.user.form_email)

        subscription.user = nil
        subscription.save!
        params = subscription.payload_for_ping_notification(resource_name: ResourceSubscription::CANCELLED_RESOURCE_NAME)

        expect(params[:resource_name]).to eq(ResourceSubscription::CANCELLED_RESOURCE_NAME)
        expect(params[:user_id]).to be(nil)
        expect(params[:user_email]).to eq(original_purchase_email)
      end
    end

    context "ended event" do
      it "contains the subscription ending details if the subscription ended after a fixed subscription length" do
        ended_at = 1.minute.ago
        subscription = create(:subscription, ended_at:, deactivated_at: ended_at)
        create(:membership_purchase, subscription:)

        payload = subscription.payload_for_ping_notification(resource_name: ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME)

        expect(payload[:resource_name]).to eq ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME
        expect(payload[:ended_at]).to eq ended_at.as_json
        expect(payload[:ended_reason]).to eq "fixed_subscription_period_ended"
      end

      it "contains the subscription ending details if the subscription was cancelled" do
        ended_at = 1.minute.ago
        subscription = create(:subscription, cancelled_at: ended_at, deactivated_at: ended_at)
        create(:membership_purchase, subscription:)

        payload = subscription.payload_for_ping_notification(resource_name: ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME)

        expect(payload[:resource_name]).to eq ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME
        expect(payload[:ended_at]).to eq ended_at.as_json
        expect(payload[:ended_reason]).to eq "cancelled"
      end

      it "contains the subscription ending details if the subscription was terminated due to failed payments" do
        ended_at = 1.minute.ago
        subscription = create(:subscription, failed_at: ended_at, deactivated_at: ended_at)
        create(:membership_purchase, subscription:)

        payload = subscription.payload_for_ping_notification(resource_name: ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME)

        expect(payload[:resource_name]).to eq ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME
        expect(payload[:ended_at]).to eq ended_at.as_json
        expect(payload[:ended_reason]).to eq "failed_payment"
      end

      it "contains empty subscription ending details if the subscription has not ended" do
        subscription = create(:subscription)
        create(:membership_purchase, subscription:)

        payload = subscription.payload_for_ping_notification(resource_name: ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME)

        expect(payload[:resource_name]).to eq ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME
        expect(payload[:ended_at]).to be_nil
        expect(payload[:ended_reason]).to be_nil
      end
    end

    context "passing additional parameters" do
      it "includes those parameters in the payload" do
        subscription = create(:subscription)
        create(:membership_purchase, subscription:)

        payload = subscription.payload_for_ping_notification(resource_name: ResourceSubscription::SUBSCRIPTION_UPDATED_RESOURCE_NAME, additional_params: { foo: "bar" })

        expect(payload[:resource_name]).to eq ResourceSubscription::SUBSCRIPTION_UPDATED_RESOURCE_NAME
        expect(payload[:foo]).to eq "bar"
      end
    end
  end
end
