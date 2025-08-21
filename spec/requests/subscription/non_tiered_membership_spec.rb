# frozen_string_literal: true

require "spec_helper"

describe "Non Tiered Membership Subscriptions", type: :system, js: true do
  include ManageSubscriptionHelpers
  include ProductWantThisHelpers

  context "that are active" do
    before :each do
      @originally_subscribed_at = Time.utc(2020, 04, 01)
      travel_to @originally_subscribed_at do
        product = create(:subscription_product, user: create(:user), name: "This is a subscription product", subscription_duration: BasePrice::Recurrence::MONTHLY, price_cents: 12_99)
        @variant = create(:variant, variant_category: create(:variant_category, link: product))
        @monthly_price = product.prices.find_by!(recurrence: BasePrice::Recurrence::MONTHLY)
        @quarterly_price = create(:price, link: product, recurrence: BasePrice::Recurrence::QUARTERLY, price_cents: 30_00)
        @yearly_price = create(:price, link: product, recurrence: BasePrice::Recurrence::YEARLY, price_cents: 99_99)
        @subscription_without_purchaser = create(:subscription,
                                                 user: nil,
                                                 credit_card: create(:credit_card, card_type: "paypal", braintree_customer_id: "blah", visual: "test@gum.co"),
                                                 link: product)
        create(:purchase, is_original_subscription_purchase: true,
                          link: product,
                          subscription: @subscription_without_purchaser,
                          credit_card: @subscription_without_purchaser.credit_card)

        @purchaser = create(:user, credit_card: create(:credit_card, chargeable: build(:chargeable, card: StripePaymentMethodHelper.success_charge_decline)))
        @credit_card = create(:credit_card)
        @subscription_with_purchaser = create(:subscription, credit_card: @credit_card, user: @purchaser, link: product, price: @quarterly_price)
        @purchase = create(:purchase, is_original_subscription_purchase: true,
                                      link: product,
                                      subscription: @subscription_with_purchaser,
                                      credit_card: @credit_card,
                                      price: @quarterly_price,
                                      variant_attributes: [@variant],
                                      price_cents: @quarterly_price.price_cents)
      end

      travel_to @originally_subscribed_at + 1.month
      setup_subscription_token(subscription: @subscription_with_purchaser)
    end

    it "displays the payment method that'll be used for future charges" do
      visit "/subscriptions/#{@subscription_with_purchaser.external_id}/manage?token=#{@subscription_with_purchaser.token}"
      expect(page).to have_selector("[aria-label=\"Saved credit card\"]", text: /#{ChargeableVisual.get_card_last4(@credit_card.visual)}$/)
    end

    it "allows updating the subscription's credit card" do
      visit "/subscriptions/#{@subscription_with_purchaser.external_id}/manage?token=#{@subscription_with_purchaser.token}"

      click_on "Use a different card?"

      fill_in_credit_card(number: StripePaymentMethodHelper.success[:cc_number])
      click_on "Update membership"
      wait_for_ajax

      expect(page).to have_alert(text: "Your membership has been updated.")
      expect(@subscription_with_purchaser.reload.credit_card).not_to eq @credit_card
      expect(@subscription_with_purchaser.credit_card).to be_present
      expect(@subscription_with_purchaser.price.id).to eq(@quarterly_price.id)

      # Make sure recurring charges with the new card succeed
      expect do
        travel_to(@subscription_with_purchaser.end_time_of_subscription + 1.day) do
          @subscription_with_purchaser.charge!
        end
      end.to change { @subscription_with_purchaser.purchases.successful.count }.by(1)
    end

    it "allows updating the subscription's credit card to an SCA-enabled card" do
      visit "/subscriptions/#{@subscription_with_purchaser.external_id}/manage?token=#{@subscription_with_purchaser.token}"

      click_on "Use a different card?"

      fill_in_credit_card(number: StripePaymentMethodHelper.success_with_sca[:cc_number])
      click_on "Update membership"
      wait_for_ajax
      sleep 1
      within_sca_frame do
        find_and_click("button:enabled", text: /COMPLETE/)
      end

      expect(page).to have_alert(text: "Your membership has been updated.")
      expect(@subscription_with_purchaser.reload.credit_card).not_to eq @credit_card
      expect(@subscription_with_purchaser.credit_card).to be

      # Make sure recurring charges with the new card succeed
      expect do
        travel_to(@subscription_with_purchaser.end_time_of_subscription + 1.day) do
          @subscription_with_purchaser.charge!
        end
      end.to change { @subscription_with_purchaser.purchases.successful.count }.by(1)
    end

    it "does not update the subscription's credit card if SCA fails" do
      visit "/subscriptions/#{@subscription_with_purchaser.external_id}/manage?token=#{@subscription_with_purchaser.token}"

      click_on "Use a different card?"

      fill_in_credit_card(number: StripePaymentMethodHelper.success_with_sca[:cc_number])
      click_on "Update membership"
      wait_for_ajax
      sleep 1
      within_sca_frame do
        find_and_click("button:enabled", text: /FAIL/)
      end

      expect(page).to have_alert(text: "We are unable to authenticate your payment method. Please choose a different payment method and try again.")
      expect(@subscription_with_purchaser.reload.credit_card).to eq @credit_card
    end

    it "allows updating the subscription's credit card to an Indian card which requires SCA and mandate" do
      visit "/subscriptions/#{@subscription_with_purchaser.external_id}/manage?token=#{@subscription_with_purchaser.token}"

      click_on "Use a different card?"

      fill_in_credit_card(number: StripePaymentMethodHelper.success_indian_card_mandate[:cc_number])
      click_on "Update membership"
      wait_for_ajax
      sleep 1
      within_sca_frame do
        find_and_click("button:enabled", text: /COMPLETE/)
      end

      expect(page).to have_alert(text: "Your membership has been updated.")
      expect(@subscription_with_purchaser.reload.credit_card).not_to eq @credit_card
      expect(@subscription_with_purchaser.credit_card).to be
      expect(@subscription_with_purchaser.credit_card.stripe_setup_intent_id).to be_present
      expect(Stripe::SetupIntent.retrieve(@subscription_with_purchaser.credit_card.stripe_setup_intent_id).mandate).to be_present
    end

    context "changing plans" do
      it "allows upgrading the subscription recurrence" do
        visit "/subscriptions/#{@subscription_with_purchaser.external_id}/manage?token=#{@subscription_with_purchaser.token}"

        select "Yearly", from: "Recurrence"
        expect(page).to have_text "You'll be charged US$80.21 today" # prorated price 1 month into the billing period

        expect do
          click_on "Update membership"
          wait_for_ajax

          expect(page).to have_alert(text: "Your membership has been updated.")
        end.to change { @subscription_with_purchaser.purchases.successful.count }.by(1)
           .and change { @subscription_with_purchaser.purchases.not_charged.count }.by(1)

        expect(SendPurchaseReceiptJob).to have_enqueued_sidekiq_job(@subscription_with_purchaser.purchases.last.id).on("critical")
        price = @subscription_with_purchaser.reload.price
        expect(price.id).to eq(@yearly_price.id)
        expect(price.recurrence).to eq(BasePrice::Recurrence::YEARLY)
        purchase = @subscription_with_purchaser.purchases.last
        expect(purchase.successful?).to eq(true)
        expect(purchase.id).to_not eq(@purchase.id)
        expect(purchase.displayed_price_cents).to eq(80_21)
        expect(@purchase.reload.is_archived_original_subscription_purchase?).to eq true
        new_template_purchase = @subscription_with_purchaser.original_purchase
        expect(new_template_purchase.id).not_to eq @purchase.id
        expect(new_template_purchase.displayed_price_cents).to eq 99_99
        expect(new_template_purchase.variant_attributes).to eq [@variant]
      end

      it "allows downgrading the subscription recurrence" do
        visit "/subscriptions/#{@subscription_with_purchaser.external_id}/manage?token=#{@subscription_with_purchaser.token}"

        select "Monthly", from: "Recurrence"
        expect(page).not_to have_text "You'll be charged"

        expect do
          expect do
            click_on "Update membership"
            wait_for_ajax

            expect(page).to have_alert(text: "Your membership will be updated at the end of your current billing cycle.")
          end.not_to have_enqueued_mail(CustomerMailer, :receipt)
        end.to change { @subscription_with_purchaser.purchases.successful.count }.by(0)
           .and change { @subscription_with_purchaser.purchases.not_charged.count }.by(0)

        expect(@subscription_with_purchaser.reload.subscription_plan_changes.count).to eq 1
        expect(@subscription_with_purchaser.price.recurrence).to eq "quarterly"
        expect(@subscription_with_purchaser.original_purchase.displayed_price_cents).to eq 30_00
        plan_change = @subscription_with_purchaser.subscription_plan_changes.first
        expect(plan_change.recurrence).to eq "monthly"
        expect(plan_change.perceived_price_cents).to eq 12_99
      end
    end

    it "allow to cancel and restart membership" do
      visit "/subscriptions/#{@subscription_with_purchaser.external_id}/manage?token=#{@subscription_with_purchaser.token}"

      click_on "Cancel membership"
      wait_for_ajax

      expect(page).to have_button("Cancelled", disabled: true)
      expect(page).to have_button("Restart membership")

      click_on "Restart membership"
      wait_for_ajax

      expect(page).to(have_alert(text: "Membership restarted"))
      expect(page).to have_button("Update membership")
      expect(page).to have_button("Cancel membership")
    end
  end

  context "that are inactive" do
    before do
      travel_to(1.month.ago) do
        product = create(:subscription_product)
        @credit_card = create(:credit_card, chargeable: build(:chargeable, card: StripePaymentMethodHelper.success))

        @subscription_without_purchaser = create(:subscription,
                                                 user: nil,
                                                 credit_card: @credit_card,
                                                 link: product,
                                                 cancelled_at: 1.week.from_now,
                                                 deactivated_at: 1.week.from_now,
                                                 cancelled_by_buyer: true)
        create(:purchase, is_original_subscription_purchase: true, link: product, subscription: @subscription_without_purchaser, created_at: 1.month.ago, credit_card: @credit_card)

        @purchaser = create(:user, credit_card: @credit_card)
        @subscription_with_purchaser = create(:subscription, credit_card: @credit_card, user: @purchaser, link: product, failed_at: Time.current, deactivated_at: Time.current)
        create(:purchase, is_original_subscription_purchase: true, link: product, subscription: @subscription_with_purchaser, created_at: 1.month.ago, credit_card: @credit_card)
        create(:purchase, link: product, subscription: @subscription_with_purchaser, purchase_state: "failed", credit_card: @credit_card)
      end

      setup_subscription_token(subscription: @subscription_with_purchaser)
      setup_subscription_token(subscription: @subscription_without_purchaser)
    end

    it "displays existing payment method and does not show cancel membership button" do
      visit "/subscriptions/#{@subscription_with_purchaser.external_id}/manage?token=#{@subscription_with_purchaser.token}"

      expect(page).to have_selector("[aria-label=\"Saved credit card\"]", text: /#{ChargeableVisual.get_card_last4(@credit_card.visual)}$/)
      expect(page).not_to have_button("Cancel")
    end

    it "restarts membership with existing payment method" do
      visit "/subscriptions/#{@subscription_with_purchaser.external_id}/manage?token=#{@subscription_with_purchaser.token}"

      click_on "Restart membership"
      wait_for_ajax

      expect(page).to(have_alert(text: "Membership restarted"))
      expect(@subscription_with_purchaser.reload.alive?(include_pending_cancellation: false)).to be(true)
      expect(@subscription_with_purchaser.purchases.successful.count).to eq(2)
    end

    it "restarts membership with new payment method and updates the card for the subscription but not the user's card" do
      visit "/subscriptions/#{@subscription_with_purchaser.external_id}/manage?token=#{@subscription_with_purchaser.token}"

      click_on "Use a different card?"
      fill_in_credit_card(number: StripePaymentMethodHelper.success[:cc_number])
      click_on "Restart membership"
      wait_for_ajax

      expect(page).to(have_alert(text: "Membership restarted"))
      expect(@subscription_with_purchaser.reload.alive?(include_pending_cancellation: false)).to be(true)
      expect(@subscription_with_purchaser.purchases.successful.count).to eq(2)
      expect(@subscription_with_purchaser.credit_card_id).not_to eq @credit_card.id
      expect(@subscription_with_purchaser.user.credit_card_id).to eq @credit_card.id
    end

    it "does not restart if charge fails on existing card" do
      credit_card = create(:credit_card, chargeable: build(:chargeable, card: StripePaymentMethodHelper.success_charge_decline))
      @subscription_with_purchaser.update!(credit_card:)
      @purchaser.update!(credit_card:)

      visit "/subscriptions/#{@subscription_with_purchaser.external_id}/manage?token=#{@subscription_with_purchaser.token}"

      click_on "Restart membership"
      wait_for_ajax

      expect(page).to have_alert(text: "Your card was declined.")
      expect(@subscription_with_purchaser.reload.alive?(include_pending_cancellation: false)).to be(false)
      expect(@subscription_with_purchaser.purchases.successful.count).to eq(1)
      expect(@subscription_with_purchaser.purchases.failed.count).to eq(1)
    end

    context "without a purchaser" do
      it "restarts membership with the existing payment method" do
        visit "/subscriptions/#{@subscription_without_purchaser.external_id}/manage?token=#{@subscription_without_purchaser.token}"

        click_on "Restart membership"
        wait_for_ajax

        expect(page).to(have_alert(text: "Membership restarted"))
        expect(@subscription_without_purchaser.reload.alive?(include_pending_cancellation: false)).to be(true)
        expect(@subscription_without_purchaser.purchases.successful.count).to eq(2)
        expect(@subscription_without_purchaser.credit_card_id).to eq @credit_card.id
      end

      it "restarts membership with new payment method and updates the card for user" do
        visit "/subscriptions/#{@subscription_without_purchaser.external_id}/manage?token=#{@subscription_without_purchaser.token}"

        click_on "Use a different card?"
        fill_in_credit_card(number: StripePaymentMethodHelper.success[:cc_number])
        click_on "Restart membership"

        expect(page).to(have_alert(text: "Membership restarted"))
        expect(@subscription_without_purchaser.reload.alive?(include_pending_cancellation: false)).to be(true)
        expect(@subscription_without_purchaser.purchases.successful.count).to eq(2)
        expect(@subscription_without_purchaser.credit_card_id).not_to eq @credit_card.id
      end
    end

    it "does not restart if charge fails on existing card" do
      credit_card = create(:credit_card, chargeable: build(:chargeable, card: StripePaymentMethodHelper.success_charge_decline))
      @subscription_without_purchaser.update!(credit_card:)

      visit "/subscriptions/#{@subscription_without_purchaser.external_id}/manage?token=#{@subscription_without_purchaser.token}"

      click_on "Restart membership"
      wait_for_ajax

      expect(page).to have_alert(text: "Your card was declined.")
      expect(@subscription_without_purchaser.reload.alive?(include_pending_cancellation: false)).to be(false)
      expect(@subscription_without_purchaser.purchases.count).to eq(1)
    end

    it "does not restart membership or update card if charge fails on new card" do
      visit "/subscriptions/#{@subscription_without_purchaser.external_id}/manage?token=#{@subscription_without_purchaser.token}"

      click_on "Use a different card?"
      fill_in_credit_card(number: StripePaymentMethodHelper.success_charge_decline[:cc_number])
      click_on "Restart membership"
      wait_for_ajax

      expect(page).to have_alert(text: "Your card was declined.")
      expect(@subscription_without_purchaser.reload.alive?(include_pending_cancellation: false)).to be(false)
      expect(@subscription_without_purchaser.purchases.count).to eq(1)
    end
  end

  context "that are overdue for charge but not inactive" do
    it "allows the user to update their card and charges the new card" do
      travel_to(1.month.ago)
      product = create(:subscription_product)
      credit_card = create(:credit_card, chargeable: build(:chargeable, card: StripePaymentMethodHelper.success))
      subscription = create(:subscription, user: nil, credit_card:, link: product)
      create(:purchase, is_original_subscription_purchase: true, link: product, subscription:, created_at: 1.month.ago, credit_card:)
      create(:purchase, link: product, subscription:, purchase_state: "failed", credit_card:)
      travel_back

      setup_subscription_token(subscription: subscription)

      visit "/subscriptions/#{subscription.external_id}/manage?token=#{subscription.token}"

      click_on "Use a different card?"
      fill_in_credit_card(number: StripePaymentMethodHelper.success[:cc_number])
      click_on "Update membership"
      wait_for_ajax

      expect(page).to have_alert(text: "Your membership has been updated.")
      expect(subscription.reload.credit_card).not_to eq credit_card
      expect(subscription.credit_card).to be_present
      expect(subscription.purchases.successful.count).to eq 2
    end
  end

  context "that are for physical products" do # we have some historical physical subscription products
    before do
      product = create(:physical_product, price_cents: 27_00, subscription_duration: "monthly")
      product.is_recurring_billing = true
      product.save(validate: false)
      price = product.prices.first
      price.update!(recurrence: "monthly")

      @credit_card = create(:credit_card)
      @subscription = create(:subscription, link: product, credit_card: @credit_card, price:)
      create(:physical_purchase, link: product, subscription: @subscription,
                                 is_original_subscription_purchase: true,
                                 variant_attributes: [product.skus.first])

      setup_subscription_token
    end

    it "allows updating the subscription's credit card" do
      visit "/subscriptions/#{@subscription.external_id}/manage?token=#{@subscription.token}"

      click_on "Use a different card?"

      fill_in_credit_card(number: StripePaymentMethodHelper.success[:cc_number])
      click_on "Update membership"
      click_on "Yes, it is" # verify shipping address
      wait_for_ajax

      expect(page).to have_alert(text: "Your membership has been updated.")
      expect(@subscription.reload.credit_card).not_to eq @credit_card
      expect(@subscription.credit_card).to be_present
    end
  end
end
