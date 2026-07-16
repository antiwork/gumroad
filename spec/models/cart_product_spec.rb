# frozen_string_literal: true

require "spec_helper"

describe CartProduct do
  describe "callbacks" do
    it "assigns default url parameters after initialization" do
      cart_product = build(:cart_product)
      expect(cart_product.url_parameters).to eq({})
    end

    it "assigns accepted offer details after initialization" do
      cart_product = build(:cart_product)
      expect(cart_product.accepted_offer_details).to eq({})
    end
  end

  describe "validations" do
    describe "quantity" do
      context "when quantity is a positive integer within the column range" do
        it "marks the cart product as valid" do
          cart_product = build(:cart_product, quantity: 1)
          expect(cart_product).to be_valid
        end
      end

      context "when quantity is zero" do
        it "marks the cart product as invalid" do
          cart_product = build(:cart_product, quantity: 0)
          expect(cart_product).to be_invalid
          expect(cart_product.errors.full_messages.join).to include("Quantity must be greater than 0")
        end
      end

      context "when quantity is negative" do
        it "marks the cart product as invalid" do
          cart_product = build(:cart_product, quantity: -1)
          expect(cart_product).to be_invalid
          expect(cart_product.errors.full_messages.join).to include("Quantity must be greater than 0")
        end
      end

      context "when quantity exceeds the 4-byte integer column limit" do
        it "marks the cart product as invalid instead of raising a range error on save" do
          cart_product = build(:cart_product, quantity: CartProduct::MAX_QUANTITY + 1)
          expect(cart_product).to be_invalid
          expect(cart_product.errors.full_messages.join).to include("Quantity must be less than or equal to #{CartProduct::MAX_QUANTITY}")
          expect { cart_product.save! }.to raise_error(ActiveRecord::RecordInvalid)
        end
      end

      context "when quantity is at the 4-byte integer column limit" do
        it "marks the cart product as valid" do
          cart_product = build(:cart_product, quantity: CartProduct::MAX_QUANTITY)
          expect(cart_product).to be_valid
        end
      end
    end

    describe "price" do
      context "when price is within the bigint column range" do
        it "marks the cart product as valid" do
          cart_product = build(:cart_product, price: CartProduct::MAX_PRICE)
          expect(cart_product).to be_valid
        end
      end

      context "when price is negative" do
        it "marks the cart product as invalid" do
          cart_product = build(:cart_product, price: -1)
          expect(cart_product).to be_invalid
          expect(cart_product.errors.full_messages.join).to include("Price must be greater than or equal to 0")
        end
      end

      context "when price exceeds the 8-byte integer column limit" do
        it "marks the cart product as invalid instead of raising a range error on save" do
          cart_product = build(:cart_product, price: 10_000_000_000_000_000_000_000)
          expect(cart_product).to be_invalid
          expect(cart_product.errors.full_messages.join).to include("Price must be less than or equal to #{CartProduct::MAX_PRICE}")
          expect { cart_product.save! }.to raise_error(ActiveRecord::RecordInvalid)
        end
      end
    end

    describe "url parameters" do
      context "when url parameters are empty" do
        it "marks the cart product as valid" do
          cart_product = build(:cart_product, url_parameters: {})
          expect(cart_product).to be_valid
        end
      end

      context "when url parameters is not a hash" do
        it "marks the cart product as invalid" do
          cart_product = build(:cart_product, url_parameters: [])
          expect(cart_product).to be_invalid
          expect(cart_product.errors.full_messages.join).to include("The property '#/' of type array did not match the following type: object")
        end
      end

      context "when url parameters contain invalid keys" do
        it "marks the cart product as invalid" do
          cart_product = build(:cart_product, url_parameters: { "hello" => 123 })
          expect(cart_product).to be_invalid
          expect(cart_product.errors.full_messages.join).to include("The property '#/hello' of type integer did not match the following type: string in schema")
        end
      end
    end

    describe "accepted offer details" do
      context "when accepted offer details is empty" do
        it "marks the cart product as valid" do
          cart_product = build(:cart_product, accepted_offer_details: {})
          expect(cart_product).to be_valid
        end
      end

      context "when accepted offer details is not a hash" do
        it "marks the cart product as invalid" do
          cart_product = build(:cart_product, accepted_offer_details: [])
          expect(cart_product).to be_invalid
          expect(cart_product.errors.full_messages.join).to include("The property '#/' of type array did not match the following type: object")
        end
      end

      context "when accepted offer details contains invalid keys" do
        it "marks the cart product as invalid" do
          cart_product = build(:cart_product, accepted_offer_details: { "hello" => 123 })
          expect(cart_product).to be_invalid
          expect(cart_product.errors.full_messages.join).to include("The property '#/' contains additional properties [\"hello\"] outside of the schema when none are allowed in schema")
        end
      end

      context "allows original_variant_id to be nil" do
        it "marks the cart product as valid" do
          cart_product = build(:cart_product, accepted_offer_details: { original_product_id: "123", original_variant_id: nil })
          expect(cart_product).to be_valid

          cart_product = build(:cart_product, accepted_offer_details: { original_product_id: "123", original_variant_id: "456" })
          expect(cart_product).to be_valid
        end
      end
    end
  end
end
