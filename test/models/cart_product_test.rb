# frozen_string_literal: true

require "test_helper"

class CartProductTest < ActiveSupport::TestCase
  self.described_class = CartProduct



  context_ CartProduct do
  context_ "callbacks" do
  test "assigns default url parameters after initialization" do
        cart_product = build(:cart_product)
        expect(cart_product.url_parameters).to eq({})
      end

  test "assigns accepted offer details after initialization" do
        cart_product = build(:cart_product)
        expect(cart_product.accepted_offer_details).to eq({})
      end
    end

  context_ "validations" do
  context_ "url parameters" do
  context_ "when url parameters are empty" do
  test "marks the cart product as valid" do
            cart_product = build(:cart_product, url_parameters: {})
            expect(cart_product).to be_valid
          end
        end

  context_ "when url parameters is not a hash" do
  test "marks the cart product as invalid" do
            cart_product = build(:cart_product, url_parameters: [])
            expect(cart_product).to be_invalid
            expect(cart_product.errors.full_messages.join).to include("The property '#/' of type array did not match the following type: object")
          end
        end

  context_ "when url parameters contain invalid keys" do
  test "marks the cart product as invalid" do
            cart_product = build(:cart_product, url_parameters: { "hello" => 123 })
            expect(cart_product).to be_invalid
            expect(cart_product.errors.full_messages.join).to include("The property '#/hello' of type integer did not match the following type: string in schema")
          end
        end
      end

  context_ "accepted offer details" do
  context_ "when accepted offer details is empty" do
  test "marks the cart product as valid" do
            cart_product = build(:cart_product, accepted_offer_details: {})
            expect(cart_product).to be_valid
          end
        end

  context_ "when accepted offer details is not a hash" do
  test "marks the cart product as invalid" do
            cart_product = build(:cart_product, accepted_offer_details: [])
            expect(cart_product).to be_invalid
            expect(cart_product.errors.full_messages.join).to include("The property '#/' of type array did not match the following type: object")
          end
        end

  context_ "when accepted offer details contains invalid keys" do
  test "marks the cart product as invalid" do
            cart_product = build(:cart_product, accepted_offer_details: { "hello" => 123 })
            expect(cart_product).to be_invalid
            expect(cart_product.errors.full_messages.join).to include("The property '#/' contains additional properties [\"hello\"] outside of the schema when none are allowed in schema")
          end
        end

  context_ "allows original_variant_id to be nil" do
  test "marks the cart product as valid" do
            cart_product = build(:cart_product, accepted_offer_details: { original_product_id: "123", original_variant_id: nil })
            expect(cart_product).to be_valid

            cart_product = build(:cart_product, accepted_offer_details: { original_product_id: "123", original_variant_id: "456" })
            expect(cart_product).to be_valid
          end
        end
      end
    end
  end
end
