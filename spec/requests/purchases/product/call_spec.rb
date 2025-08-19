# frozen_string_literal: true

require "spec_helper"

describe "Call", type: :system, js: true do
  let!(:seller) { create(:named_seller, :eligible_for_service_products) }
  let!(:call) do
    create(
      :call_product,
      :available_for_a_year,
      name: "Call me!",
      description: "Call me for business advices.",
      user: seller,
      price_cents: 10_00,
      durations: []
    )
  end
  let!(:call_limitation_info) { create(:call_limitation_info, call:, minimum_notice_in_minutes: 0, maximum_calls_per_day: 10) }
  let!(:long_availability) { create(:call_availability, call:, start_time: Time.current, end_time: 2.months.from_now) }
  let!(:variant_category) { call.variant_categories.first }

  let(:client_time_zone) { ActiveSupport::TimeZone.new("UTC") }
  let(:first_day_of_next_month) { client_time_zone.now.next_month.beginning_of_month }

  around do |example|
    travel_to Time.zone.local(2024, 9, 15) do
      example.run
    end
  end

  context "one duration" do
    let!(:duration_30) { create(:variant, name: "30 minutes", variant_category:, price_difference_cents: 0, duration_in_minutes: 30) }

    it "allows selecting from the available dates and times" do
      visit call.long_url

      expect(page).to have_radio_button("$10", checked: true)

      wait_for_ajax

      within_section "Select a date" do
        expect(page).to have_text("September 2024")
        click_on "Next month"
        expect(page).to have_text("October 2024")

        click_on "1", match: :first
      end

      within_section "Select a time" do
        choose "01:00 PM"
      end

      expect(page).to have_text("You selected Tuesday, October 1 at 01:00 PM")

      scroll_to first("footer")
      click_on "I want this!"
      expect(page).to have_current_path("/checkout")

      within_cart_item "Call me!" do
        expect(page).to have_text("Duration: 30 minutes")
        expect(page).to have_text("Tuesday, October 1 at 01:00 PM UTC")
      end

      fill_checkout_form(call)
      click_on "Pay"
      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

      purchase = Purchase.last
      expect(purchase).to be_successful
      expect(purchase.price_cents).to eq(10_00)
      expect(purchase.link).to eq(call)
      expect(purchase.variant_attributes).to eq([duration_30])

      start_time = Time.zone.local(2024, 10, 1, 13, 0)
      expect(purchase.call.start_time).to eq(start_time)
      expect(purchase.call.end_time).to eq(start_time + 30.minutes)
    end
  end

  context "multiple durations" do
    let!(:duration_30) { create(:variant, name: "30 minutes", variant_category:, price_difference_cents: 0, duration_in_minutes: 30) }
    let!(:duration_60) { create(:variant, name: "60 minutes", variant_category:, price_difference_cents: 10_00, duration_in_minutes: 60) }

    it "allows selecting a duration and changing it during checkout" do
      visit call.long_url

      expect(page).to have_radio_button("$10", checked: true)
      expect(page).to have_radio_button("$20", checked: false)

      wait_for_ajax

      choose "$10"

      scroll_to first("footer")
      click_on "I want this!"
      expect(page).to have_current_path("/checkout")

      within_cart_item "Call me!" do
        expect(page).to have_text("Duration: 30 minutes")

        select_disclosure "Configure" do
          choose "$20"
          click_on "Next month"
          click_on "1", match: :first
          choose "01:00 PM"
          expect(page).to have_text("You selected Tuesday, October 1 at 01:00 PM")
          click_on "Save changes"
        end
      end
      within_cart_item "Call me!" do
        expect(page).to have_text("Duration: 60 minutes")
      end

      fill_checkout_form(call)
      click_on "Pay"
      expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to test@gumroad.com.")

      purchase = Purchase.last
      expect(purchase).to be_successful
      expect(purchase.price_cents).to eq(20_00)
      expect(purchase.link).to eq(call)
      expect(purchase.variant_attributes).to eq([duration_60])
      expect(purchase.call).to be_present

      start_time = Time.zone.local(2024, 10, 1, 13, 0)
      expect(purchase.call.start_time).to eq(start_time)
      expect(purchase.call.end_time).to eq(start_time + 60.minutes)
    end
  end
end
