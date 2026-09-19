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
      create(
        :product,
        name: "Buy me a coffee!",
        user: create(:named_seller, :eligible_for_service_products),
        native_type: Link::NATIVE_TYPE_COFFEE,
      )
    end
    let(:purchase) { create(:purchase, link: coffee) }

    before do
      category = coffee.variant_categories_alive.first
      # The page snapshots the amounts that predate the purchase, and created_at is stored to the
      # second, so backdate them: otherwise the page renders one amount (or none) and this example
      # never reaches the multi-amount rule it claims to cover.
      older = 1.hour.ago
      category.alive_variants.each { |variant| variant.update!(created_at: older) }
      create(:variant, name: "", variant_category: category, price_difference_cents: 200, created_at: older)
    end

    it "keeps the custom-amount CTA live instead of asking for a SKU" do
      visit purchase_product_path(purchase.external_id)

      expect(page).to have_text("Buy me a coffee!")
      # Both amounts are on screen and one is preselected, so the amount field only exists once
      # "Other" is chosen — that blank optionId is the Other amount, not a missing SKU.
      expect(page).to have_css("[role='radio']", text: "Other")
      expect(page).to_not have_field("Name a fair price")
      expect(page).to_not have_link("Choose an option")

      find("[role='radio']", text: "Other").click

      # A blank optionId is exactly the state a non-coffee product would guard.
      expect(page).to_not have_link("Choose an option")
      fill_in "Name a fair price", with: "5"
      first("a[href*='/checkout']").click

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
