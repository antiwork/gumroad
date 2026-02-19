# frozen_string_literal: true

require "spec_helper"

describe "Subscription restart at checkout", :js, type: :system do
  before do
    @seller = create(:named_user)
    @product = create(:membership_product, user: @seller, price_cents: 500)
    @tier = @product.default_tier
    @buyer = create(:user)
    @credit_card = create(:credit_card, user: @buyer)
    @buyer.update!(credit_card: @credit_card)

    @subscription = create(:subscription, link: @product, user: @buyer, credit_card: @credit_card)
    travel_to(5.minutes.ago) do
      create(:purchase,
             is_original_subscription_purchase: true,
             link: @product,
             subscription: @subscription,
             purchaser: @buyer,
             email: @buyer.email,
             credit_card: @credit_card,
             variant_attributes: [@tier],
             price_cents: @product.price_cents)
    end

    @subscription.update!(cancelled_at: 1.day.ago, deactivated_at: 1.day.ago, cancelled_by_buyer: true)
  end

  context "with existing card" do
    before do
      # Stub UpdaterService to avoid real Stripe charges while keeping RestartAtCheckoutService integration
      updater_double = instance_double(Subscription::UpdaterService)
      allow(Subscription::UpdaterService).to receive(:new).and_return(updater_double)
      allow(updater_double).to receive(:perform) do
        Subscription.find(@subscription.id).resubscribe!
        { success: true, success_message: "Your membership has been restarted!" }
      end
    end

    it "restarts the cancelled subscription instead of creating a new one" do
      login_as @buyer
      visit "/checkout?product=#{@product.unique_permalink}&option=#{@tier.external_id}&quantity=1"

      expect(page).to have_cart_item(@product.name)
      fill_checkout_form(@product, logged_in_user: @buyer, email: @buyer.email)

      click_on "Pay", exact: true
      expect(page).to have_text("Your purchase was successful!")

      expect(@subscription.reload).to be_alive
      expect(@subscription.cancelled_at).to be_nil
      expect(@product.subscriptions.count).to eq(1)
    end
  end

  context "when the restart requires 3D Secure" do
    before do
      @seller.update!(check_merchant_account_is_linked: true)
      @merchant_account = create(:merchant_account_stripe_connect, user: @seller)
      @buyer.update!(credit_card: nil)

      # Create a real Stripe PaymentIntent on the Connect account that requires 3DS action.
      # UpdaterService's off_session charge auto-succeeds for test cards, so we pre-create
      # the PI and stub UpdaterService to return it.
      @payment_intent = Stripe::PaymentIntent.create(
        {
          amount: 10_00,
          currency: "usd",
          payment_method: "pm_card_threeDSecure2Required",
          payment_method_types: ["card"],
          confirm: true,
        },
        { stripe_account: @merchant_account.charge_processor_merchant_id }
      )

      tier_price_cents = @product.read_attribute(:price_cents)
      @upgrade_purchase = create(:purchase_in_progress,
                                 link: @product,
                                 purchaser: @buyer,
                                 email: @buyer.email,
                                 subscription: @subscription,
                                 price_cents: tier_price_cents,
                                 variant_attributes: [@tier],
                                 merchant_account: @merchant_account)
      @upgrade_purchase.create_processor_payment_intent!(intent_id: @payment_intent.id)

      updater_double = instance_double(Subscription::UpdaterService)
      allow(Subscription::UpdaterService).to receive(:new).and_return(updater_double)
      allow(updater_double).to receive(:perform) do
        sub = Subscription.find(@subscription.id)
        sub.resubscribe!
        sub.update_flag!(:is_resubscription_pending_confirmation, true, true)
        {
          success: true,
          requires_card_action: true,
          client_secret: @payment_intent.client_secret,
          purchase: {
            id: @upgrade_purchase.external_id,
            stripe_connect_account_id: @merchant_account.charge_processor_merchant_id
          }
        }
      end
    end

    it "completes the SCA challenge and restarts the subscription" do
      login_as @buyer
      visit "/checkout?product=#{@product.unique_permalink}&option=#{@tier.external_id}&quantity=1"

      expect(page).to have_cart_item(@product.name)
      fill_checkout_form(@product, logged_in_user: @buyer, email: @buyer.email,
                                   credit_card: { number: "4000002500003155" })

      click_on "Pay", exact: true
      within_sca_frame { click_on "Complete" }

      expect(page).to have_text("Your purchase was successful!")

      expect(@subscription.reload).to be_alive
      expect(@subscription.cancelled_at).to be_nil
      expect(@product.subscriptions.count).to eq(1)
    end
  end
end
