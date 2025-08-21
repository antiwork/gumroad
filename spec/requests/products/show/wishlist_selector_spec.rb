# frozen_string_literal: true

require("spec_helper")

describe "Product page wishlist selector", js: true, type: :system do
  let(:user) { create(:user) }
  let(:product) { create(:product, user:) }

  def add_to_wishlist(option, expected_name: option)
    select_combo_box_option option, from: "Add to wishlist"
    expect(page).to have_combo_box("Add to wishlist", text: expected_name)
  end

  context "when not logged in" do
    it "redirects to the login page" do
      visit product.long_url
      find(:combo_box, "Add to wishlist").click
      expect(current_url).to eq(login_url(host: DOMAIN, next: product.long_url))
    end
  end

  context "when logged in" do
    before { login_as(user) }

    it "supports creating new wishlists" do
      visit product.long_url

      expect { add_to_wishlist("New wishlist", expected_name: "Wishlist 1") }.to change(user.wishlists, :count).by(1)
      expect(page).to have_alert(text: "Wishlist created")
      expect(user.wishlists.last.products).to contain_exactly(product)
      expect(user.wishlists.last.name).to eq("Wishlist 1")

      expect { add_to_wishlist("New wishlist", expected_name: "Wishlist 2") }.to change(user.wishlists, :count).by(1)
      expect(page).to have_alert(text: "Wishlist created")
      expect(user.wishlists.last.products).to contain_exactly(product)
      expect(user.wishlists.last.name).to eq("Wishlist 2")

      find(:combo_box, "Add to wishlist").click
      expect(page).to have_combo_box("Add to wishlist", with_disabled_options: ["Wishlist 1", "Wishlist 2"])
    end

    context "with an existing wishlist" do
      let(:existing_wishlist) { create(:wishlist, name: "My Wishlist", user:) }
      let(:existing_product) { create(:product, user:) }

      before do
        create(:wishlist_product, wishlist: existing_wishlist, product: existing_product)
      end

      it "supports adding to the wishlist" do
        visit product.long_url

        expect { add_to_wishlist("My Wishlist") }.to change(existing_wishlist.wishlist_products, :count).by(1)
        expect(page).to have_alert(text: "Added to wishlist")
        find(:combo_box, "Add to wishlist").click
        expect(page).to have_combo_box("Add to wishlist", with_disabled_options: ["My Wishlist"])

        expect(existing_wishlist.reload.products).to contain_exactly(existing_product, product)
      end

      it "supports creating a new wishlist" do
        visit product.long_url

        expect { add_to_wishlist("New wishlist", expected_name: "Wishlist 2") }.to change(user.wishlists, :count).by(1)
        expect(page).to have_alert(text: "Wishlist created")

        expect(existing_wishlist.reload.products).to contain_exactly(existing_product)
        expect(user.wishlists.last.products).to contain_exactly(product)
        expect(user.wishlists.last.name).to eq("Wishlist 2")
      end
    end

    context "for a membership product" do
      let(:product) do
        create(:membership_product_with_preset_tiered_pricing, user:, recurrence_price_values: [
                 { "monthly": { enabled: true, price: 3 }, "yearly": { enabled: true, price: 30 } },
                 { "monthly": { enabled: true, price: 5 }, "yearly": { enabled: true, price: 50 } }
               ])
      end

      it "saves the tier and recurrence" do
        visit product.long_url

        add_to_wishlist("New wishlist", expected_name: "Wishlist 1")
        expect(user.wishlists.last.wishlist_products.sole).to have_attributes(
          recurrence: "monthly",
          variant: product.tiers.first
        )

        find(:combo_box, "Add to wishlist").click
        expect(page).to have_combo_box("Add to wishlist", with_disabled_options: ["Wishlist 1"])

        choose("Second Tier")
        select("Yearly", from: "Recurrence")
        add_to_wishlist("Wishlist 1")

        expect(user.wishlists.last.wishlist_products.count).to eq 2
        expect(user.wishlists.last.wishlist_products.reload.last).to have_attributes(
          recurrence: "yearly",
          variant: product.tiers.second
        )

        find(:combo_box, "Add to wishlist").click
        expect(page).to have_combo_box("Add to wishlist", with_disabled_options: ["Wishlist 1"])
      end
    end

    context "for a physical product" do
      let(:product) { create(:product, :is_physical) }

      before do
        variant_category = create(:variant_category, link: product)
        %w[Red Blue Green].each { |name| create(:variant, name:, variant_category:) }
        Product::SkusUpdaterService.new(product:).perform
      end

      it "saves the sku and quantity" do
        visit product.long_url

        add_to_wishlist("New wishlist", expected_name: "Wishlist 1")
        expect(user.wishlists.last.wishlist_products.sole).to have_attributes(
          quantity: 1,
          variant: product.skus.not_is_default_sku.first
        )

        choose("Green")
        fill_in "Quantity", with: 4
        add_to_wishlist("Wishlist 1")

        expect(user.wishlists.last.wishlist_products.count).to eq 2
        expect(user.wishlists.last.wishlist_products.reload.last).to have_attributes(
          quantity: 4,
          variant: product.skus.not_is_default_sku.last
        )
      end
    end

    context "for a rental product" do
      let(:product) { create(:product, purchase_type: :buy_and_rent, rental_price_cents: 100) }

      it "saves rental or non-rental without duplicating the wishlist item" do
        visit product.long_url

        add_to_wishlist("New wishlist", expected_name: "Wishlist 1")
        expect(user.wishlists.last.wishlist_products.sole).to have_attributes(product:, rent: false)

        choose("Rent")
        add_to_wishlist("Wishlist 1")

        expect(user.wishlists.last.wishlist_products.sole).to have_attributes(product:, rent: true)
      end
    end
  end
end
