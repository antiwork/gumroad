# frozen_string_literal: true

describe Subscription::RestartAtCheckoutService do
  let(:seller) { create(:user) }
  let(:product) { create(:membership_product, user: seller) }
  let(:buyer) { create(:user) }
  let(:email) { buyer.email }
  let(:browser_guid) { SecureRandom.uuid }

  let(:base_params) do
    {
      purchase: {
        email: email,
        perceived_price_cents: product.price_cents,
        browser_guid: browser_guid
      },
      price_id: product.prices.alive.first.external_id
    }
  end

  def create_subscription_for_product(product:, purchaser:, email:, **subscription_attrs)
    subscription = create(:subscription, link: product, user: purchaser)
    create(:purchase,
           link: product,
           purchaser: purchaser,
           email: email,
           subscription: subscription,
           is_original_subscription_purchase: true,
           price_cents: product.price_cents,
           variant_attributes: product.tiers.to_a
    )
    subscription.update!(subscription_attrs) if subscription_attrs.present?
    subscription
  end

  describe "#perform" do
    context "with a cancelled subscription that can be restarted" do
      let!(:subscription) do
        create_subscription_for_product(
          product: product,
          purchaser: buyer,
          email: email,
          cancelled_at: 1.day.ago,
          cancelled_by_buyer: true,
          deactivated_at: 1.day.ago
        )
      end

      it "restarts the subscription" do
        service = described_class.new(
          subscription: subscription,
          product: product,
          params: base_params,
          buyer: buyer
        )

        result = service.perform

        expect(result[:success]).to be true
        expect(result[:restarted_subscription]).to be true

        subscription.reload
        expect(subscription.cancelled_at).to be_nil
        expect(subscription.deactivated_at).to be_nil
        expect(subscription.cancelled_by_buyer).to be false
      end

      it "sends restart notifications" do
        expect_any_instance_of(Subscription).to receive(:send_restart_notifications!)

        service = described_class.new(
          subscription: subscription,
          product: product,
          params: base_params,
          buyer: buyer
        )

        service.perform
      end

      context "when subscription is within billing period (pending cancellation)" do
        before do
          subscription.update!(
            cancelled_at: 1.month.from_now,
            deactivated_at: nil
          )
          allow_any_instance_of(Subscription).to receive(:end_time_of_last_paid_period).and_return(1.week.from_now)
        end

        it "does not charge the user" do
          expect_any_instance_of(Subscription).not_to receive(:charge!)

          service = described_class.new(
            subscription: subscription,
            product: product,
            params: base_params,
            buyer: buyer
          )

          result = service.perform
          expect(result[:success]).to be true
          expect(result[:purchase]).to be_nil
        end
      end
    end

    context "with a failed subscription" do
      let!(:subscription) do
        create_subscription_for_product(
          product: product,
          purchaser: buyer,
          email: email,
          failed_at: 1.day.ago,
          deactivated_at: 1.day.ago
        )
      end

      it "restarts the subscription and clears the failed status" do
        service = described_class.new(
          subscription: subscription,
          product: product,
          params: base_params,
          buyer: buyer
        )

        result = service.perform

        expect(result[:success]).to be true

        subscription.reload
        expect(subscription.failed_at).to be_nil
        expect(subscription.deactivated_at).to be_nil
      end
    end

    context "when subscription is cancelled by seller" do
      let!(:subscription) do
        create_subscription_for_product(
          product: product,
          purchaser: buyer,
          email: email,
          cancelled_at: 1.day.ago,
          cancelled_by_buyer: false,
          cancelled_by_admin: true,
          deactivated_at: 1.day.ago
        )
      end

      it "returns an error" do
        service = described_class.new(
          subscription: subscription,
          product: product,
          params: base_params,
          buyer: buyer
        )

        result = service.perform

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("This subscription cannot be restarted.")
      end
    end

    context "when product is deleted" do
      let!(:subscription) do
        create_subscription_for_product(
          product: product,
          purchaser: buyer,
          email: email,
          cancelled_at: 1.day.ago,
          cancelled_by_buyer: true,
          deactivated_at: 1.day.ago
        )
      end

      before do
        product.update!(deleted_at: 1.hour.ago)
      end

      it "returns an error" do
        service = described_class.new(
          subscription: subscription,
          product: product,
          params: base_params,
          buyer: buyer
        )

        result = service.perform

        expect(result[:success]).to be false
        expect(result[:error_message]).to eq("This subscription cannot be restarted.")
      end
    end
  end
end
