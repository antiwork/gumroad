# frozen_string_literal: true

require("spec_helper")

describe("Purchase product page", type: :system, js: true) do
  let(:purchase) { create(:purchase) }
  let(:product) { purchase.link }

  it "shows the product for the purchase" do
    visit purchase_product_path(purchase.external_id)

    expect(page).to have_text(product.name)
  end

  describe "Refund policy" do
    before do
      purchase.create_purchase_refund_policy!(
        title: ProductRefundPolicy::ALLOWED_REFUND_PERIODS_IN_DAYS[30],
        max_refund_period_in_days: 30,
        fine_print: "This is the fine print of the refund policy."
      )
    end

    it "renders the refund period" do
      visit purchase_product_path(purchase.external_id)

      expect(page).to have_text("30-day money back guarantee")
      expect(page).not_to have_text("This is the fine print of the refund policy.")
    end

    context "when the URL contains refund-policy anchor" do
      it "does not open a fine-print modal or record a view event" do
        expect do
          visit purchase_product_path(purchase.external_id, anchor: "refund-policy")
        end.not_to change { Event.count }

        expect(page).to have_text("30-day money back guarantee")
        expect(page).not_to have_selector("[role='dialog']")
      end
    end
  end
end
