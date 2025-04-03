# frozen_string_literal: true

require "spec_helper"

describe WishlistProduct do
  describe "validations" do
    let(:wishlist) { create(:wishlist) }
    let(:product) { create(:product) }
    let(:wishlist_product) { described_class.new(wishlist:, product:) }

    it "validates the product is unique in the wishlist" do
      wishlist_product.save!

      wishlist_product2 = described_class.new(wishlist:, product: wishlist_product.product)
      expect(wishlist_product2).to be_invalid
      expect(wishlist_product2.errors.full_messages.first).to eq "Product has already been taken"
    end

    context "for a non recurring product" do
      it "validates recurrence is blank" do
        wishlist_product.recurrence = BasePrice::Recurrence::MONTHLY
        expect(wishlist_product).to be_invalid
        expect(wishlist_product.errors.full_messages.first).to eq "Recurrence must be blank"

        wishlist_product.recurrence = nil
        expect(wishlist_product).to be_valid
      end
    end

    context "for a recurring product" do
      let(:product) { create(:product, :is_subscription) }

      it "validates recurrence is a known value" do
        wishlist_product.recurrence = BasePrice::Recurrence::MONTHLY
        expect(wishlist_product).to be_valid

        wishlist_product.recurrence = nil
        expect(wishlist_product).to be_invalid
        expect(wishlist_product.errors.full_messages.first).to eq "Recurrence is not included in the list"

        wishlist_product.recurrence = "unknown"
        expect(wishlist_product).to be_invalid
        expect(wishlist_product.errors.full_messages.first).to eq "Recurrence is not included in the list"
      end

      it "allows different recurrence in the same wishlist" do
        product = create(:subscription_product)
        wishlist_product.update!(recurrence: BasePrice::Recurrence::MONTHLY)

        wishlist_product2 = described_class.new(wishlist:, product:, recurrence: BasePrice::Recurrence::YEARLY)
        expect(wishlist_product2).to be_valid
      end
    end

    context "when the product does not support quantity" do
      it "validates the quantity is always 1" do
        wishlist_product.quantity = 4
        expect(wishlist_product).to be_invalid
        expect(wishlist_product.errors.full_messages.first).to eq "Quantity must be equal to 1"

        wishlist_product.quantity = 1
        expect(wishlist_product).to be_valid
      end
    end

    context "when the product supports quantity" do
      let(:product) { create(:product, :is_physical) }

      it "validates the quantity is greater than zero" do
        wishlist_product.quantity = 4
        expect(wishlist_product).to be_valid

        wishlist_product.quantity = -1
        expect(wishlist_product).to be_invalid
        expect(wishlist_product.errors.full_messages.first).to eq "Quantity must be greater than 0"
      end
    end

    context "when the product is buy-only" do
      it "validates rent is not set" do
        wishlist_product.rent = true
        expect(wishlist_product).to be_invalid
        expect(wishlist_product.errors.full_messages.first).to eq "Rent must be blank"

        wishlist_product.rent = false
        expect(wishlist_product).to be_valid
      end
    end

    context "when the product is rent-only" do
      let(:product) { create(:product, purchase_type: :rent_only, rental_price_cents: 100) }

      it "validates rent is set" do
        wishlist_product.rent = false
        expect(wishlist_product).to be_invalid
        expect(wishlist_product.errors.full_messages.first).to eq "Rent can't be blank"

        wishlist_product.rent = true
        expect(wishlist_product).to be_valid
      end
    end

    context "when the product is buy-or-rent" do
      let(:product) { create(:product, purchase_type: :buy_and_rent, rental_price_cents: 100) }

      it "allows rent to be set or unset" do
        wishlist_product.rent = false
        expect(wishlist_product).to be_valid

        wishlist_product.rent = true
        expect(wishlist_product).to be_valid
      end
    end

    context "when the product is versioned" do
      let(:product) { create(:product_with_digital_versions) }

      it "validates variant is set" do
        expect(wishlist_product).to_not be_valid
        expect(wishlist_product.errors.full_messages.first).to eq("Wishlist product must have variant specified for versioned product")

        wishlist_product.variant = product.alive_variants.first
        expect(wishlist_product).to be_valid
      end

      it "allows different variants in the same wishlist" do
        wishlist_product.update!(variant: product.variants.first)
        wishlist_product2 = described_class.new(wishlist:, product:, variant: product.variants.last)
        expect(wishlist_product2).to be_valid
      end
    end

    context "when the variant doesn't belong to the product" do
      before do
        wishlist_product.variant = create(:variant)
      end

      it "adds an error" do
        expect(wishlist_product).to_not be_valid
        expect(wishlist_product.errors.full_messages.first).to eq("The wishlist product's variant must belong to its product")
      end
    end

    context "when adding products to a wishlist" do
      it "allows adding products up to the limit" do
        create_list(:wishlist_product, WishlistProduct::WISHLIST_PRODUCT_LIMIT - 1, wishlist:)

        new_product = build(:wishlist_product, wishlist:)
        expect(new_product).to be_valid
      end

      it "prevents adding products beyond the limit" do
        create_list(:wishlist_product, WishlistProduct::WISHLIST_PRODUCT_LIMIT, wishlist:)

        new_product = build(:wishlist_product, wishlist:)
        expect(new_product).to be_invalid
        expect(new_product.errors.full_messages.first).to eq "A wishlist can have at most #{WishlistProduct::WISHLIST_PRODUCT_LIMIT} products"
      end

      it "allows adding products after deleting existing ones" do
        create_list(:wishlist_product, WishlistProduct::WISHLIST_PRODUCT_LIMIT, wishlist:)

        wishlist.wishlist_products.first.mark_deleted!
        new_product = build(:wishlist_product, wishlist:)
        expect(new_product).to be_valid
      end
    end
  end

  describe ".available_to_buy" do
    let!(:valid_wishlist_product) { create(:wishlist_product) }

    it "filters out products with a suspended user" do
      create(:wishlist_product, product: create(:product, user: create(:tos_user)))

      expect(described_class.available_to_buy).to contain_exactly valid_wishlist_product
    end

    it "filters out unpublished products" do
      create(:wishlist_product, product: create(:product, purchase_disabled_at: Time.current))

      expect(described_class.available_to_buy).to contain_exactly valid_wishlist_product
    end
  end
end
