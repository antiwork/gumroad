# frozen_string_literal: true

require "spec_helper"

describe "Subscription manage page tier upgrade with SCA", :js, type: :system do
  include ManageSubscriptionHelpers

  before do
    MerchantAccount.find_or_create_by!(user_id: nil, charge_processor_id: StripeChargeProcessor.charge_processor_id) do |ma|
      ma.charge_processor_alive_at = Time.current
    end

    setup_subscription(recurrence: BasePrice::Recurrence::QUARTERLY)
    travel_to(@originally_subscribed_at + 1.month)
    setup_subscription_token

    @seller = @product.user
    @seller.update!(check_merchant_account_is_linked: true)
    @merchant_account = create(:merchant_account_stripe_connect, user: @seller)

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

    @upgrade_purchase = create(:purchase_in_progress,
                               link: @product,
                               purchaser: @user,
                               email: @user.email,
                               subscription: @subscription,
                               price_cents: @new_tier_quarterly_price.price_cents,
                               variant_attributes: [@new_tier],
                               merchant_account: @merchant_account)
    @upgrade_purchase.create_processor_payment_intent!(intent_id: @payment_intent.id)

    updater_double = instance_double(Subscription::UpdaterService)
    allow(Subscription::UpdaterService).to receive(:new).and_return(updater_double)
    allow(updater_double).to receive(:perform) do
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

  it "completes the tier upgrade after 3D Secure challenge" do
    visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

    choose "Second Tier"
    expect(page).to have_text "You'll be charged"

    click_on "Update membership"
    within_sca_frame { click_on "Complete" }

    expect(page).to have_alert(text: "Your membership has been updated.")
  end

  it "handles SCA failure" do
    visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

    choose "Second Tier"
    click_on "Update membership"
    within_sca_frame { click_on "Fail" }

    expect(@upgrade_purchase.reload).not_to be_successful
  end
end
