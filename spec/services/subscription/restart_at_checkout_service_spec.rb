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
      price_id: product.prices.alive.first.external_id,
      variants: product.tiers.map(&:external_id)
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
    let(:updater_service) { instance_double(Subscription::UpdaterService) }

    before do
      allow(Subscription::UpdaterService).to receive(:new).and_return(updater_service)
    end

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

      it "delegates to UpdaterService with correct params" do
        allow(updater_service).to receive(:perform).and_return({ success: true, success_message: "Membership restarted" })

        service = described_class.new(
          subscription: subscription,
          product: product,
          params: base_params,
          buyer: buyer
        )

        result = service.perform

        expect(result[:success]).to be true
        expect(result[:restarted_subscription]).to be true
        expect(result[:message]).to eq("Membership restarted")

        expect(Subscription::UpdaterService).to have_received(:new).with(
          subscription: subscription,
          params: hash_including(
            variants: product.tiers.map(&:external_id),
            price_id: product.prices.alive.first.external_id,
            quantity: 1,
            perceived_price_cents: product.price_cents,
            perceived_upgrade_price_cents: product.price_cents,
            use_existing_card: true
          ),
          logged_in_user: buyer,
          gumroad_guid: browser_guid,
          remote_ip: nil
        )
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

      it "delegates to UpdaterService and returns success" do
        allow(updater_service).to receive(:perform).and_return({ success: true, success_message: "Membership restarted" })

        service = described_class.new(
          subscription: subscription,
          product: product,
          params: base_params,
          buyer: buyer
        )

        result = service.perform

        expect(result[:success]).to be true
        expect(result[:restarted_subscription]).to be true
      end
    end

    context "when UpdaterService returns an error" do
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

      it "passes through the error" do
        allow(updater_service).to receive(:perform).and_return({ success: false, error_message: "This subscription cannot be restarted." })

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

      it "returns an error from UpdaterService" do
        allow(updater_service).to receive(:perform).and_return({ success: false, error_message: "This subscription cannot be restarted." })

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

      before { product.update!(deleted_at: 1.hour.ago) }

      it "returns an error from UpdaterService" do
        allow(updater_service).to receive(:perform).and_return({ success: false, error_message: "This subscription cannot be restarted." })

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

    context "when UpdaterService requires card action (SCA)" do
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

      it "passes through SCA details" do
        allow(updater_service).to receive(:perform).and_return({
          success: true,
          requires_card_action: true,
          client_secret: "pi_secret_123"
        })

        service = described_class.new(
          subscription: subscription,
          product: product,
          params: base_params,
          buyer: buyer
        )

        result = service.perform

        expect(result[:success]).to be true
        expect(result[:requires_card_action]).to be true
        expect(result[:client_secret]).to eq("pi_secret_123")
      end
    end

    context "param transformation" do
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

      it "defaults variants and price_id from subscription when not provided" do
        allow(updater_service).to receive(:perform).and_return({ success: true })

        params_without_variants = {
          purchase: {
            email: email,
            perceived_price_cents: product.price_cents,
            browser_guid: browser_guid
          }
        }

        described_class.new(
          subscription: subscription,
          product: product,
          params: params_without_variants,
          buyer: buyer
        ).perform

        expect(Subscription::UpdaterService).to have_received(:new).with(
          subscription: subscription,
          params: hash_including(
            variants: subscription.original_purchase.variant_attributes.map(&:external_id),
            price_id: subscription.price&.external_id,
            use_existing_card: true
          ),
          logged_in_user: buyer,
          gumroad_guid: browser_guid,
          remote_ip: nil
        )
      end

      it "falls back to subscription price when perceived_price_cents not provided" do
        allow(updater_service).to receive(:perform).and_return({ success: true })

        params_without_price = {
          purchase: { email: email, browser_guid: browser_guid },
          variants: product.tiers.map(&:external_id),
          price_id: product.prices.alive.first.external_id
        }

        described_class.new(
          subscription: subscription,
          product: product,
          params: params_without_price,
          buyer: buyer
        ).perform

        expect(Subscription::UpdaterService).to have_received(:new).with(
          subscription: subscription,
          params: hash_including(
            perceived_price_cents: subscription.current_subscription_price_cents,
            perceived_upgrade_price_cents: subscription.current_subscription_price_cents
          ),
          logged_in_user: buyer,
          gumroad_guid: browser_guid,
          remote_ip: nil
        )
      end
    end
  end
end
