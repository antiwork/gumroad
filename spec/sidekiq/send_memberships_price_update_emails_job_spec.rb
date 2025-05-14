# frozen_string_literal: true

describe SendMembershipsPriceUpdateEmailsJob do
  describe "#perform" do
    let(:subscription) { create(:subscription) }
    let(:effective_on) { rand(1..7).days.from_now.to_date }

    before do
      allow(CustomerLowPriorityMailer).to receive(:subscription_price_change_notification).and_return(double(deliver_later: true))
    end

    context "when there are applicable subscription plan changes" do
      let!(:applicable_plan_change) do
        create(:subscription_plan_change, for_product_price_change: true, subscription:,
                                          effective_on:, perceived_price_cents: 20_00)
      end

      it "sends notification emails for applicable changes", :freeze_time do
        expect do
          subject.perform
        end.to change { applicable_plan_change.reload.notified_subscriber_at }.from(nil).to(Time.current)

        expect(CustomerLowPriorityMailer).to have_received(:subscription_price_change_notification).with(
          subscription_id: subscription.id,
          new_price: 20_00
        )
      end

      it "does not send notification emails for subscriptions pending cancellation" do
        subscription.update!(cancelled_at: effective_on + 1.day)

        expect do
          subject.perform
        end.not_to change { applicable_plan_change.reload.notified_subscriber_at }

        expect(CustomerLowPriorityMailer).not_to have_received(:subscription_price_change_notification)
      end

      it "does not send notification emails for subscriptions that are fully cancelled" do
        subscription.update!(cancelled_at: 1.day.ago, deactivated_at: 1.day.ago)

        expect do
          subject.perform
        end.not_to change { applicable_plan_change.reload.notified_subscriber_at }

        expect(CustomerLowPriorityMailer).not_to have_received(:subscription_price_change_notification)
      end

      it "does not send notification emails for subscriptions that have ended" do
        subscription.update!(ended_at: 1.day.ago, deactivated_at: 1.day.ago)

        expect do
          subject.perform
        end.not_to change { applicable_plan_change.reload.notified_subscriber_at }

        expect(CustomerLowPriorityMailer).not_to have_received(:subscription_price_change_notification)
      end

      it "does not send notification emails for subscriptions that have failed" do
        subscription.update!(failed_at: 1.day.ago, deactivated_at: 1.day.ago)

        expect do
          subject.perform
        end.not_to change { applicable_plan_change.reload.notified_subscriber_at }

        expect(CustomerLowPriorityMailer).not_to have_received(:subscription_price_change_notification)
      end
    end

    context "when there are non-applicable subscription plan changes" do
      before do
        create(:subscription_plan_change, for_product_price_change: false, subscription:, effective_on:)
        create(:subscription_plan_change, for_product_price_change: true, subscription:, effective_on:, applied: true)
        create(:subscription_plan_change, for_product_price_change: true, subscription:, effective_on:, deleted_at: Time.current)
        create(:subscription_plan_change, for_product_price_change: true, subscription:, effective_on:, notified_subscriber_at: Time.current)
        create(:subscription_plan_change, for_product_price_change: true, subscription:, effective_on: 8.days.from_now.to_date)
      end

      it "does not send any emails" do
        subject.perform
        expect(CustomerLowPriorityMailer).not_to have_received(:subscription_price_change_notification)
      end
    end

    context "when there are no subscription plan changes" do
      it "does not send any emails" do
        subject.perform
        expect(CustomerLowPriorityMailer).not_to have_received(:subscription_price_change_notification)
      end
    end
  end
end
