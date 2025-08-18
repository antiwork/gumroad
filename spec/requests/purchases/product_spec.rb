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
        title: "This is a product-level refund policy",
        fine_print: "This is the fine print of the refund policy."
      )
    end

    it "renders refund policy" do
      visit purchase_product_path(purchase.external_id)

      click_on("This is a product-level refund policy")
      within_modal "This is a product-level refund policy" do
        expect(page).to have_text("This is the fine print of the refund policy.")
      end
    end

    context "when the URL contains refund-policy anchor" do
      it "renders with the modal open and creates event" do
        expect do
          visit purchase_product_path(purchase.external_id, anchor: "refund-policy")
        end.to change { Event.count }.by(1)

        within_modal "This is a product-level refund policy" do
          expect(page).to have_text("This is the fine print of the refund policy.")
        end

        event = Event.last
        expect(event.event_name).to eq(Event::NAME_PRODUCT_REFUND_POLICY_FINE_PRINT_VIEW)
        expect(event.link_id).to eq(product.id)
      end
    end
  end
end
