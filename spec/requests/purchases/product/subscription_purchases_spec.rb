# frozen_string_literal: true

require("spec_helper")
require "timeout"

describe("Subscription Purchases from the product page", type: :system, js: true) do
  context "purchasing memberships with multiple tiers" do
    before do
      @membership_product = create(:membership_product_with_preset_tiered_pricing)
      tier_category = @membership_product.tier_category
      @first_tier = tier_category.variants.first
      @second_tier = tier_category.variants.last
      @second_tier.update!(max_purchase_count: 1)
    end

    it "allows the user to purchase a tier" do
      visit "/l/#{@membership_product.unique_permalink}"

      expect(page).to have_radio_button("Second Tier", text: "1 left")

      add_to_cart(@membership_product, option: "Second Tier")

      check_out(@membership_product)
    end

    context "with multiple recurrences" do
      before do
        @first_tier.save_recurring_prices!("monthly" => { enabled: true, price: 2 }, "yearly" => { enabled: true, price: 10 })
        @second_tier.save_recurring_prices!("monthly" => { enabled: true, price: 3 }, "yearly" => { enabled: true, price: 14 })
      end

      it "allows to switch the recurrence and shows tiers' prices for that recurrence" do
        visit "/l/#{@membership_product.unique_permalink}"

        select "Yearly", from: "Recurrence"

        expect(page).to have_radio_button("First Tier", text: "$10")
        expect(page).to have_radio_button("Second Tier", text: "$14")

        select "Monthly", from: "Recurrence"

        expect(page).to have_radio_button("First Tier", text: "$2")
        expect(page).to have_radio_button("Second Tier", text: "$3")
      end

      it "proceeds with the purchase successfully after making a recurrence and tier selection" do
        visit "/l/#{@membership_product.unique_permalink}"

        select "Yearly", from: "Recurrence"

        expect(page).to have_radio_button("First Tier", text: "$10")
        expect(page).to have_radio_button("Second Tier", text: "$14")

        add_to_cart(@membership_product, option: "Second Tier")

        expect(page).to have_text("Total US$14", normalize_ws: true)

        check_out(@membership_product)

        purchase = Purchase.successful.last
        expect(purchase.subscription.price).to eq @membership_product.prices.find_by!(recurrence: BasePrice::Recurrence::YEARLY)
        expect(purchase.variant_attributes.map(&:id)).to eq [@second_tier.id]
        expect(purchase.custom_fee_per_thousand).to be_nil
        expect(purchase.fee_cents).to eq(261) # 10% of $14 + 50c + 2.9% of $14 + 30c

        @membership_product.user.update!(custom_fee_per_thousand: 25)
        travel_to(1.year.from_now)
        expect(purchase.seller.reload.custom_fee_per_thousand).to eq(25)
        RecurringChargeWorker.new.perform(purchase.subscription.id)

        recurring_charge = purchase.subscription.purchases.successful.last
        expect(purchase.subscription.purchases.successful.count).to eq(2)
        expect(recurring_charge.custom_fee_per_thousand).to be_nil
        expect(recurring_charge.fee_cents).to eq(261)
      end

      it "charges custom Gumroad fee if custom fee is set for the seller" do
        @membership_product.user.update!(custom_fee_per_thousand: 50)

        visit "/l/#{@membership_product.unique_permalink}"

        select "Yearly", from: "Recurrence"

        expect(page).to have_radio_button("First Tier", text: "$10")
        expect(page).to have_radio_button("Second Tier", text: "$14")

        add_to_cart(@membership_product, option: "Second Tier")

        expect(page).to have_text("Total US$14", normalize_ws: true)

        check_out(@membership_product)

        purchase = Purchase.successful.last
        expect(purchase.subscription.price).to eq @membership_product.prices.find_by!(recurrence: BasePrice::Recurrence::YEARLY)
        expect(purchase.variant_attributes.map(&:id)).to eq [@second_tier.id]
        expect(purchase.custom_fee_per_thousand).to eq(50)
        expect(purchase.fee_cents).to eq(191) # 5% of $14 + 50c + 2.9% of $14 + 30c

        @membership_product.user.update!(custom_fee_per_thousand: 25)
        travel_to(1.year.from_now)
        expect(purchase.seller.reload.custom_fee_per_thousand).to eq(25)
        RecurringChargeWorker.new.perform(purchase.subscription.id)

        recurring_charge = purchase.subscription.purchases.successful.last
        expect(purchase.subscription.purchases.successful.count).to eq(2)
        expect(recurring_charge.custom_fee_per_thousand).to eq(50)
        expect(recurring_charge.fee_cents).to eq(191)
      end

      context "when a tier has pay-what-you-want enabled" do
        before do
          @second_tier.update!(customizable_price: true)
          @second_tier.save_recurring_prices!("monthly" => { enabled: true, price: 3, suggested_price: 5 }, "yearly" => { enabled: true, price: 14, suggested_price: 20 })
        end

        it "reflects PWYW-ability in the price tag of that tier (and that tier only)" do
          visit "/l/#{@membership_product.unique_permalink}"

          expect(page).to have_radio_button("First Tier", text: "$2")
          expect(page).to have_radio_button("Second Tier", text: "$3+")

          select "Yearly", from: "Recurrence"

          expect(page).to have_radio_button("First Tier", text: "$10")
          expect(page).to have_radio_button("Second Tier", text: "$14+")
        end

        it "shows the PWYW input when selecting that tier with an appropriate suggested price for the current recurrence" do
          visit "/l/#{@membership_product.unique_permalink}"

          expect(page).not_to have_field("Name a fair price")

          choose "Second Tier"
          expect(page).to have_field("Name a fair price", placeholder: "5+", with: "")

          select "Yearly", from: "Recurrence"
          expect(page).to have_field("Name a fair price", placeholder: "20+", with: "")
        end

        it "does not allow the user to proceed with a price lower than the tier's minimum price for the current recurrence" do
          visit "/l/#{@membership_product.unique_permalink}"

          expect(page).not_to have_field("Name a fair price")

          choose "Second Tier"
          expect(page).to have_field("Name a fair price", placeholder: "5+", with: "")

          fill_in "Name a fair price", with: "2"
          click_on "Subscribe"
          expect(find_field("Name a fair price")["aria-invalid"]).to eq("true")

          add_to_cart(@membership_product, pwyw_price: 3, option: "Second Tier")

          expect(page).to have_text("Total US$3", normalize_ws: true)

          visit "/l/#{@membership_product.unique_permalink}"

          expect(page).not_to have_field("Name a fair price")

          choose "Second Tier"
          select "Yearly", from: "Recurrence"
          expect(page).to have_field("Name a fair price", placeholder: "20+", with: "")

          fill_in "Name a fair price", with: "10"
          click_on "Subscribe"
          expect(find_field("Name a fair price")["aria-invalid"]).to eq("true")

          add_to_cart(@membership_product, pwyw_price: 20, option: "Second Tier")

          expect(page).to have_text("Total US$20", normalize_ws: true)
        end

        it "proceeds with the purchase successfully when a valid custom price is entered" do
          visit "/l/#{@membership_product.unique_permalink}"

          expect(page).not_to have_field("Name a fair price")

          add_to_cart(@membership_product, option: "Second Tier", recurrence: "Yearly", pwyw_price: 20)

          expect(page).to have_text("Total US$20", normalize_ws: true)

          check_out(@membership_product)

          purchase = Purchase.successful.last
          expect(purchase.price_cents).to eq 20_00
          expect(purchase.subscription.price).to eq @membership_product.prices.find_by!(recurrence: BasePrice::Recurrence::YEARLY)
          expect(purchase.variant_attributes.map(&:id)).to eq [@second_tier.id]
        end

        it "hides the PWYW input when selecting a tier with no PWYW option" do
          visit "/l/#{@membership_product.unique_permalink}"

          expect(page).not_to have_field("Name a fair price")

          choose "Second Tier"
          expect(page).to have_field("Name a fair price")

          choose "First Tier"
          expect(page).not_to have_field("Name a fair price")
        end
      end
    end

    context "when a tier has hit the active subscriber limit" do
      it "does not allow the user to purchase that tier" do
        create(:purchase, link: @membership_product, variant_attributes: [@second_tier])
        visit "/l/#{@membership_product.unique_permalink}"
        expect(page).to have_radio_button("Second Tier", disabled: true)
      end
    end
  end

  it "assigns license keys to subscription purchases" do
    link = create(:product, is_recurring_billing: true, is_licensed: true, subscription_duration: :monthly)
    visit("/l/#{link.unique_permalink}")
    add_to_cart(link)
    check_out(link)

    purchase = Purchase.last
    expect(purchase.link).to eq link
    expect(purchase.license).to_not be(nil)
    expect(purchase.link.licenses.count).to eq 1
  end

  describe "purchasing memberships with free trials" do
    before do
      @membership_product = create(:membership_product_with_preset_tiered_pricing, free_trial_enabled: true, free_trial_duration_amount: 1, free_trial_duration_unit: :week)
    end

    it "does not immediately charge the user" do
      visit "/l/#{@membership_product.unique_permalink}"

      add_to_cart(@membership_product, option: "First Tier")

      expect(page).to have_text("one week free")
      expect(page).to have_text("$3 monthly after")

      check_out(@membership_product)

      expect(page).not_to have_content "We charged your card"
      expect(page).to have_content "We sent a receipt to test@gumroad.com"

      purchase = Purchase.last
      expect(purchase.purchase_state).to eq "not_charged"
      expect(purchase.displayed_price_cents).to eq 300
      expect(purchase.stripe_transaction_id).to be_nil
      expect(purchase.subscription).to be_alive
      expect(purchase.should_exclude_product_review?).to eq true
    end

    context "with an SCA-enabled card" do
      it "succeeds and does not immediately charge the user" do
        visit @membership_product.long_url

        add_to_cart(@membership_product, option: "First Tier")

        expect(page).to have_text("one week free")
        expect(page).to have_text("$3 monthly after")

        check_out(@membership_product, credit_card: { number: StripePaymentMethodHelper.success_with_sca[:cc_number] }, sca: true)

        expect(page).not_to have_content "We charged your card"
        expect(page).to have_content "We sent a receipt to test@gumroad.com"

        purchase = Purchase.last
        expect(purchase.purchase_state).to eq "not_charged"
        expect(purchase.displayed_price_cents).to eq 300
        expect(purchase.stripe_transaction_id).to be_nil
        expect(purchase.subscription).to be_alive
      end
    end

    context "when the purchaser has already purchased the product and is ineligible for a free trial" do
      it "displays an error message" do
        email = generate(:email)
        purchaser = create(:user, email:)
        create(:free_trial_membership_purchase, link: @membership_product, email:,
                                                purchaser:, succeeded_at: 2.months.ago)

        visit "/l/#{@membership_product.unique_permalink}"

        expect do
          add_to_cart(@membership_product, option: "First Tier")

          expect(page).to have_text("one week free")
          expect(page).to have_text("$3 monthly after")
          check_out(@membership_product, email:, error: true)
          expect(page).to have_alert "You've already purchased this product and are ineligible for a free trial"
        end.not_to change { Purchase.count }
      end
    end
  end

  describe "gifting a subscription" do
    let(:giftee_email) { "giftee@example.com" }
    let(:membership_product) { create(:membership_product_with_preset_tiered_pricing) }

    context "when it does not offer a trial" do
      it "complete purchase, gift the subscription and prevents recurring billing" do
        visit "/l/#{membership_product.unique_permalink}"
        add_to_cart(membership_product, option: "First Tier")

        expect do
          check_out(membership_product, gift: { email: giftee_email, note: "Gifting from product page!" })
        end.to change { Subscription.count }.by(1)

        expect(Purchase.all_success_states.count).to eq 2

        fill_in "Password", with: "password"
        click_button "Sign up"
        expect(page).to have_text("Done! Your account has been created.")

        subscription = Subscription.last
        expect(subscription.gift?).to eq true
        expect(subscription.user).to be_nil
        expect(subscription.email).to eq giftee_email
        expect(subscription.credit_card).to be_nil

        expect do
          travel_to(subscription.end_time_of_subscription + 1.day) do
            subscription.charge!
          end
        end.to change { subscription.purchases.successful.count }.by(0)

        purchase = subscription.purchases.last
        expect(purchase.purchase_state).to eq "failed"
        expect(purchase.error_code).to eq "credit_card_not_provided"
      end
    end

    context "when it offers a trial" do
      let(:membership_product) { create(:membership_product_with_preset_tiered_pricing, free_trial_enabled: true, free_trial_duration_amount: 1, free_trial_duration_unit: :week) }

      it "imediately charges the gifter and gifts the subscription" do
        visit "/l/#{membership_product.unique_permalink}"
        add_to_cart(membership_product, option: "First Tier")

        expect(page).to have_text("one week free")
        expect(page).to have_text("$3 monthly after")
        expect(page).to have_text("Total US$0", normalize_ws: true)
        expect(page).to_not have_text("1 month")

        check "Give as a gift"
        expect(page).to_not have_text("one week free")
        expect(page).to_not have_text("$3 monthly after")
        expect(page).to have_text("1 month")
        expect(page).to have_text("Total US$3", normalize_ws: true)

        uncheck "Give as a gift"
        expect(page).to have_text("one week free")
        expect(page).to have_text("$3 monthly after")

        expect do
          check_out(membership_product, gift: { email: giftee_email, note: "Gifting from product page!" })
        end.to change { Subscription.count }.by(1)

        expect(Purchase.all_success_states.count).to eq 2

        subscription = Subscription.last
        expect(subscription.credit_card).to be_nil
        expect(subscription.gift?).to eq true
        expect(subscription.user).to be_nil

        purchase = subscription.original_purchase
        expect(purchase.purchase_state).to eq "successful"
        expect(purchase.is_gift_sender_purchase).to eq true
        expect(purchase.email).to eq "test@gumroad.com"

        expect(purchase.gift).to have_attributes(
          link: membership_product,
          gift_note: "Gifting from product page!"
        )

        expect(purchase.gift.giftee_purchase).to have_attributes(
          email: giftee_email,
          is_original_subscription_purchase: false
        )
      end
    end
  end
end
