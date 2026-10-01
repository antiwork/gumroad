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
             price_cents: 500)
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

  context "with the India mandate feature" do
    before do
      Feature.activate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, @seller)
      @buyer.update!(credit_card: nil)
      @subscription.update!(credit_card: nil)
    end

    after do
      Feature.deactivate_user(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, @seller)
    end

    it "keeps a guest restart stopped while Stripe reports the new mandate as pending" do
      visit "/checkout?product=#{@product.unique_permalink}&option=#{@tier.external_id}&quantity=1"

      fill_checkout_form(
        @product,
        email: @buyer.email,
        credit_card: { number: "4000003560000123" }
      )
      click_on "Pay", exact: true

      failure_message = "We could not verify this card for recurring payments."
      challenge_or_failure = <<~XPATH.squish
        //iframe[starts-with(@src, 'https://js.stripe.com/v3/three-ds-2-challenge')]
        | //*[@role='alert' and contains(normalize-space(.), '#{failure_message}')]
      XPATH
      expect(page).to have_xpath(challenge_or_failure, wait: 60)
      within_sca_frame(wait: 1) { click_on "Complete" } if page.has_selector?(SCA_CHALLENGE_IFRAME, wait: 0)

      expect(page).to have_text(failure_message)
      expect(@subscription.reload).not_to be_alive
      expect(@subscription.stripe_mandate_id).to be_nil
      expect(@subscription.credit_card).to be_nil
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
            id: @upgrade_purchase.secure_external_id(scope: "confirm", expires_at: 1.hour.from_now),
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

  context "when the cancelled membership is only a stale line in the saved cart" do
    let(:other_product) { create(:product, user: @seller, name: "Sketching bundle", price_cents: 300) }

    before do
      cart = create(:cart, user: @buyer)
      create(:cart_product, cart:, product: @product, option: @tier, created_at: 1.year.ago)
    end

    it "refuses the membership with a product-page message and buys only the other product" do
      expect(Subscription::UpdaterService).not_to receive(:new)

      login_as @buyer
      visit "/checkout?product=#{other_product.unique_permalink}&quantity=1"

      expect(page).to have_cart_item(@product.name)
      expect(page).to have_cart_item(other_product.name)
      fill_checkout_form(other_product, logged_in_user: @buyer, email: @buyer.email)

      expect do
        click_on "Pay", exact: true
        expect(page).to have_selector("[role=alert]", text: "You weren't charged for this membership. To rejoin, visit its product page.", exact_text: true)
      end.to change { other_product.sales.successful.count }.by(1)

      # The unrelated purchase is the only charge and the membership is still inactive before recovery.
      expect(@product.subscriptions.count).to eq(1)
      expect(@subscription.reload).not_to be_alive
      expect(@subscription.deactivated_at).to be_present
      expect(@product.sales.successful.count).to eq(1)
      expect(Charge.count).to eq(1)

      recovery_link = find("[role=alert]").find_link("product page")
      expect(recovery_link[:href]).to eq(@product.long_url)
      expect(recovery_link[:target]).to eq("_blank")
      expect(recovery_link[:rel]).to eq("noopener noreferrer")

      product_tab = window_opened_by { recovery_link.send_keys(:enter) }
      within_window(product_tab) do
        expect(page).to have_current_path(URI.parse(@product.long_url).request_uri, ignore_query: true)
        expect(URI.parse(page.current_url).host).to eq(URI.parse(@product.long_url).host)
      end
    end

    it "restarts the membership when the buyer arrives at checkout asking for it" do
      updater_double = instance_double(Subscription::UpdaterService)
      allow(Subscription::UpdaterService).to receive(:new).and_return(updater_double)
      allow(updater_double).to receive(:perform) do
        Subscription.find(@subscription.id).resubscribe!
        { success: true, success_message: "Your membership has been restarted!" }
      end

      login_as @buyer
      visit "/checkout?product=#{@product.unique_permalink}&option=#{@tier.external_id}&quantity=1"

      expect(page).to have_cart_item(@product.name)
      fill_checkout_form(@product, logged_in_user: @buyer, email: @buyer.email)
      click_on "Pay", exact: true

      expect(page).to have_text("Your purchase was successful!")
      expect(@subscription.reload).to be_alive
      expect(@product.subscriptions.count).to eq(1)
    end
  end
end
