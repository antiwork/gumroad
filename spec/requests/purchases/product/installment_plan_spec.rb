# frozen_string_literal: true

require "spec_helper"

describe "Product with installment plan", type: :feature, js: true do
  let!(:seller) { create(:user, tipping_enabled: true) }
  let!(:product) { create(:product, name: "Awesome product", user: seller, price_cents: 1000) }
  let!(:installment_plan) { create(:product_installment_plan, link: product, number_of_installments: 3) }

  it "allows paying in installments" do
    visit product.long_url
    expect(page).to have_text("First installment of $3.34, followed by 2 monthly installments of $3.33", normalize_ws: true)

    click_on "Pay in 3 installments"

    within_cart_item product.name do
      expect(page).to have_text("US$10 in 3 installments", normalize_ws: true)

      select_disclosure "Configure" do
        choose "Pay in full"
        click_on "Save changes"
      end
    end

    expect(page).to have_text("Subtotal US$10", normalize_ws: true)
    expect(page).to have_text("Total US$10", normalize_ws: true)
    expect(page).not_to have_text("Payment today", normalize_ws: true)
    expect(page).not_to have_text("Future installments", normalize_ws: true)

    within_cart_item product.name do
      expect(page).to_not have_text("in 3 installments")

      select_disclosure "Configure" do
        choose "Pay in 3 installments"
        click_on "Save changes"
      end
    end

    within_cart_item product.name do
      expect(page).to have_text("US$10 in 3 installments", normalize_ws: true)
    end

    expect(page).to have_text("Subtotal US$10", normalize_ws: true)
    expect(page).to have_text("Total US$10", normalize_ws: true)
    expect(page).to have_text("Payment today US$3.34", normalize_ws: true)
    expect(page).to have_text("Future installments US$6.66", normalize_ws: true)

    fill_checkout_form(product)
    click_on "Pay"

    expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

    purchase = product.sales.last
    subscription = purchase.subscription
    expect(purchase).to have_attributes(
      price_cents: 334,
      is_installment_payment: true,
      is_original_subscription_purchase: true,
    )
    expect(subscription).to have_attributes(
      is_installment_plan: true,
      charge_occurrence_count: 3,
      recurrence: "monthly",
    )
    expect(subscription.last_payment_option.installment_plan).to eq(installment_plan)

    travel_to(1.month.from_now)
    RecurringChargeWorker.new.perform(subscription.id)
    expect(subscription.purchases.successful.count).to eq(2)
    expect(subscription.purchases.successful.last).to have_attributes(
      price_cents: 333,
      is_installment_payment: true,
      is_original_subscription_purchase: false,
    )
  end

  it "does not change CTA buttons behavior when pay_in_installments parameter is present" do
    visit "#{product.long_url}?pay_in_installments=true"

    click_on "I want this!"
    within_cart_item product.name do
      expect(page).not_to have_text("in 3 installments")
    end

    visit "#{product.long_url}?pay_in_installments=true"

    click_on "Pay in 3 installments"
    within_cart_item product.name do
      expect(page).to have_text("in 3 installments")
    end
  end

  describe "gifting" do
    it "does not allow gifting when paying in installments" do
      visit product.long_url
      click_on "I want this!"

      expect(page).to have_field("Give as a gift")

      within_cart_item product.name do
        select_disclosure "Configure" do
          choose "Pay in 3 installments"
          click_on "Save changes"
        end
      end

      expect(page).not_to have_field("Give as a gift")
    end
  end

  describe "tips" do
    it "charges the full tip amount on the first payment" do
      visit product.long_url

      click_on "Pay in 3 installments"

      within_cart_item product.name do
        expect(page).to have_text("US$10 in 3 installments", normalize_ws: true)
      end

      expect(page).to have_text("Subtotal US$10", normalize_ws: true)
      expect(page).to have_text("Total US$10", normalize_ws: true)
      expect(page).to have_text("Payment today US$3.34", normalize_ws: true)
      expect(page).to have_text("Future installments US$6.66", normalize_ws: true)

      choose "10%"

      expect(page).to have_text("Subtotal US$10", normalize_ws: true)
      expect(page).to have_text("Tip US$1", normalize_ws: true)
      expect(page).to have_text("Total US$11", normalize_ws: true)
      expect(page).to have_text("Payment today US$4.34", normalize_ws: true)
      expect(page).to have_text("Future installments US$6.66", normalize_ws: true)

      fill_checkout_form(product)
      click_on "Pay"

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

      purchase = product.sales.last
      subscription = purchase.subscription
      expect(purchase).to have_attributes(
        price_cents: 434,
        is_installment_payment: true,
        is_original_subscription_purchase: true,
      )
      expect(purchase.tip.value_cents).to eq(100)
      expect(subscription).to have_attributes(
        is_installment_plan: true,
        charge_occurrence_count: 3,
        recurrence: "monthly",
      )

      travel_to(1.month.from_now)
      RecurringChargeWorker.new.perform(subscription.id)
      expect(subscription.purchases.successful.count).to eq(2)
      expect(subscription.purchases.successful.last).to have_attributes(
        price_cents: 333,
        is_installment_payment: true,
        is_original_subscription_purchase: false,
      )
      expect(subscription.purchases.successful.last.tip).to be_nil
    end
  end

  describe "discounts" do
    before { product.update!(price_cents: 1100) }

    let!(:offer_code_valid_for_one_billing_cycle) { create(:universal_offer_code, user: seller, amount_cents: 100, duration_in_billing_cycles: 1) }

    it "applies the discount to all charges even if it's only for one memebership cycle" do
      visit product.long_url + "/" + offer_code_valid_for_one_billing_cycle.code
      expect(page).to have_text("First installment of $3.34, followed by 2 monthly installments of $3.33", normalize_ws: true)

      click_on "Pay in 3 installments"

      expect(page).to have_text("Subtotal US$11", normalize_ws: true)
      expect(page).to have_text("Discounts #{offer_code_valid_for_one_billing_cycle.code} US$-1", normalize_ws: true)
      expect(page).to have_text("Total US$10", normalize_ws: true)
      expect(page).to have_text("Payment today US$3.34", normalize_ws: true)
      expect(page).to have_text("Future installments US$6.66", normalize_ws: true)

      fill_checkout_form(product)
      click_on "Pay"

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

      purchase = product.sales.last
      subscription = purchase.subscription
      expect(purchase).to have_attributes(
        price_cents: 334,
        is_installment_payment: true,
        is_original_subscription_purchase: true,
      )
      expect(subscription).to have_attributes(
        is_installment_plan: true,
        charge_occurrence_count: 3,
        recurrence: "monthly",
      )
      expect(subscription.last_payment_option.installment_plan).to eq(installment_plan)

      travel_to(1.month.from_now)
      RecurringChargeWorker.new.perform(subscription.id)
      expect(subscription.purchases.successful.count).to eq(2)
      expect(subscription.purchases.successful.last).to have_attributes(
        price_cents: 333,
        is_installment_payment: true,
        is_original_subscription_purchase: false,
      )
    end
  end

  describe "bundles" do
    let!(:course_product) { create(:product, native_type: Link::NATIVE_TYPE_COURSE, name: "Course Product", user: seller, price_cents: 500) }
    let!(:ebook_product) { create(:product, native_type: Link::NATIVE_TYPE_EBOOK, name: "Ebook Product", user: seller, price_cents: 500) }

    let!(:bundle) { create(:product, :bundle, name: "Awesome Bundle", user: seller, price_cents: 1000) }
    let!(:course_bundle_product) { create(:bundle_product, bundle:, product: course_product) }
    let!(:ebook_bundle_product) { create(:bundle_product, bundle:, product: ebook_product) }

    let!(:installment_plan) { create(:product_installment_plan, link: bundle, number_of_installments: 3) }

    it "allows paying for a bundle in installments" do
      visit bundle.long_url

      click_on "Pay in 3 installments"

      within_cart_item bundle.name do
        expect(page).to have_text("US$10 in 3 installments", normalize_ws: true)
      end

      expect(page).to have_text("Subtotal US$10", normalize_ws: true)
      expect(page).to have_text("Total US$10", normalize_ws: true)
      expect(page).to have_text("Payment today US$3.34", normalize_ws: true)
      expect(page).to have_text("Future installments US$6.66", normalize_ws: true)

      fill_checkout_form(bundle)
      click_on "Pay"

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

      purchase = bundle.sales.last
      subscription = purchase.subscription
      expect(purchase).to have_attributes(
        price_cents: 334,
        is_installment_payment: true,
        is_original_subscription_purchase: true,
      )
      expect(subscription).to have_attributes(
        is_installment_plan: true,
        charge_occurrence_count: 3,
        recurrence: "monthly",
      )
      expect(subscription.last_payment_option.installment_plan).to eq(installment_plan)

      travel_to(1.month.from_now)
      RecurringChargeWorker.new.perform(subscription.id)
      expect(subscription.purchases.successful.count).to eq(2)
      expect(subscription.purchases.successful.last).to have_attributes(
        price_cents: 333,
        is_installment_payment: true,
        is_original_subscription_purchase: false,
      )
    end
  end

  describe "tax" do
    it "calculates and charges sales tax for all installment payments when applicable" do
      visit product.long_url

      click_on "Pay in 3 installments"
      fill_checkout_form(product, zip_code: "53703")

      expect(page).to have_text("Subtotal US$10", normalize_ws: true)
      expect(page).to have_text("Sales tax US$0.55", normalize_ws: true)
      expect(page).to have_text("Total US$10.55", normalize_ws: true)

      # TODO: This is a display-only issue that we include the full tax amount
      # into "Payment today". Addressing this requires overhualing how taxes is
      # calculated for display purposes at checkout.
      expect(page).to have_text("Payment today US$3.89", normalize_ws: true)
      expect(page).to have_text("Future installments US$6.66", normalize_ws: true)

      click_on "Pay"

      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

      purchase = product.sales.last
      subscription = purchase.subscription
      expect(purchase).to have_attributes(
        price_cents: 334,
        gumroad_tax_cents: 18,
        is_installment_payment: true,
        is_original_subscription_purchase: true,
      )
      expect(subscription).to have_attributes(
        is_installment_plan: true,
        charge_occurrence_count: 3,
        recurrence: "monthly",
      )
      expect(subscription.last_payment_option.installment_plan).to eq(installment_plan)

      travel_to(1.month.from_now)
      RecurringChargeWorker.new.perform(subscription.id)
      expect(subscription.purchases.successful.count).to eq(2)
      expect(subscription.purchases.successful.last).to have_attributes(
        price_cents: 333,
        gumroad_tax_cents: 18,
        is_installment_payment: true,
        is_original_subscription_purchase: false,
      )
    end
  end
end
