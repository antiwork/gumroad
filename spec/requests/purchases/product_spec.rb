# frozen_string_literal: true

require("spec_helper")

describe("Purchase product page", type: :system, js: true) do
  let(:purchase) { create(:purchase) }
  let(:product) { purchase.link }

  it "shows the product for the purchase" do
    visit purchase_product_path(purchase.external_id)

    expect(page).to have_text(product.name)
  end

  # The coffee page itself is a different component (CoffeeProduct); this page renders the shared
  # Product component, so a coffee-aware readiness rule has to hold here too.
  context "when the purchase is for a coffee product with several amounts" do
    let(:coffee) do
      create(:product, name: "Buy me a coffee!", user: create(:named_seller), native_type: Link::NATIVE_TYPE_COFFEE)
    end
    let(:purchase) { create(:purchase, link: coffee) }

    before do
      create(:variant, name: "", variant_category: coffee.variant_categories_alive.first, price_difference_cents: 200)
    end

    it "starts on the first amount tab and lets the buyer tip a custom amount from Other" do
      visit purchase_product_path(purchase.external_id)

      expect(page).to have_radio_button("$1", checked: true)
      expect(page).to have_radio_button("Other", checked: false)

      choose "Other"
      fill_in "Name a fair price", with: "5"
      click_on "Purchase again"

      expect(page).to have_current_path(%r{\A/checkout})
    end
  end

  describe "Refund policy" do
    before do
      purchase.create_purchase_refund_policy!(
        title: ProductRefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS[30],
        max_refund_period_in_days: 30,
        fine_print: "This is the fine print of the refund policy."
      )
    end

    it "renders refund policy" do
      visit purchase_product_path(purchase.external_id)

      click_on("30-day money back guarantee")
      within_modal "30-day money back guarantee" do
        expect(page).to have_text("This is the fine print of the refund policy.")
      end
    end

    context "when the URL contains refund-policy anchor" do
      it "renders with the modal open and creates event" do
        expect do
          visit purchase_product_path(purchase.external_id, anchor: "refund-policy")
        end.to change { Event.count }.by(1)

        within_modal "30-day money back guarantee" do
          expect(page).to have_text("This is the fine print of the refund policy.")
        end

        event = Event.last
        expect(event.event_name).to eq(Event::NAME_PRODUCT_REFUND_POLICY_FINE_PRINT_VIEW)
        expect(event.link_id).to eq(product.id)
      end
    end
  end
end
