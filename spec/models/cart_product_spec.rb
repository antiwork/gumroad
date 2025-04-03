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
