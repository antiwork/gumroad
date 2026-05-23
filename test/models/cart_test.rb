# frozen_string_literal: true

require "test_helper"

class CartTest < ActiveSupport::TestCase
  self.described_class = Cart



  context_ Cart do
  context_ "associations" do
  context_ "#alive_cart_products" do
  test "returns only alive cart products" do
          cart = create(:cart)
          alive_cart_product = create(:cart_product, cart:)
          create(:cart_product, cart:, deleted_at: Time.current)
          expect(cart.alive_cart_products).to eq([alive_cart_product])
        end
      end
    end

  context_ "callbacks" do
  test "assigns default discount codes after initialization" do
        cart = build(:cart)
        expect(cart.discount_codes).to eq([])
      end
    end

  context_ "validations" do
  context_ "discount codes" do
  context_ "when discount codes are not provided" do
  test "marks the cart as valid" do
            cart = build(:cart, discount_codes: [])
            expect(cart).to be_valid
          end
        end

  context_ "when discount codes are not an array" do
  test "marks the cart as invalid" do
            cart = build(:cart, discount_codes: {})
            expect(cart).to be_invalid
            expect(cart.errors.full_messages.join).to include("The property '#/' of type object did not match the following type: array")
          end
        end

  context_ "when required fields are missing from discount codes" do
  test "marks the cart as invalid" do
            cart = build(:cart, discount_codes: [{}])
            expect(cart).to be_invalid
            errors = cart.errors.full_messages.join("\n")
            expect(errors).to include("The property '#/0' did not contain a required property of 'code'")
            expect(errors).to include("The property '#/0' did not contain a required property of 'fromUrl'")
          end
        end

  context_ "when discount codes are valid" do
  test "marks the cart as valid" do
            cart = build(:cart, discount_codes: [{ code: "ABC123", fromUrl: false }, { code: "DEF456", fromUrl: true }])
            expect(cart).to be_valid
          end
        end
      end

  context_ "alive carts per user" do
  context_ "when user is present" do
  test "validates the user only has one alive cart" do
            user = create(:user)
            first_cart = create(:cart, user:)
            second_cart = build(:cart, user:)
            expect(second_cart).to be_invalid
            expect(second_cart.errors.full_messages).to include("An alive cart already exists")
            first_cart.mark_deleted!
            expect(second_cart).to be_valid
          end
        end

  context_ "when browser_guid is present and user is not present" do
  test "validates that there is only one alive cart per browser_guid for a non-logged-in user" do
            browser_guid = "123"
            create(:cart, :guest, browser_guid:)
            create(:cart, browser_guid:)
            cart = build(:cart, :guest, browser_guid:)
            expect(cart).to be_invalid
            expect(cart.errors.full_messages).to include("An alive cart already exists")
          end
        end
      end
    end

  context_ "scopes" do
  context_ "abandoned" do
  test "does not return deleted carts" do
          cart = create(:cart)
          cart.mark_deleted!
          expect(Cart.abandoned).not_to include(cart)
        end

  test "does not return carts that have been last updated more than a month ago" do
          cart = create(:cart, updated_at: 32.days.ago)
          expect(Cart.abandoned).not_to include(cart)
        end

  test "does not return carts that have been last updated less than 24 hours ago" do
          cart = create(:cart, updated_at: 23.hours.ago)
          expect(Cart.abandoned).not_to include(cart)
        end

  test "does not return carts that have been sent an abandoned cart email" do
          cart = create(:cart)
          create(:cart_product, cart:)
          create(:sent_abandoned_cart_email, cart:)
          cart.update!(updated_at: 25.hours.ago)

          expect(Cart.abandoned).not_to include(cart)
        end

  test "does not return carts that have no alive cart products" do
          cart = create(:cart)
          create(:cart_product, cart:, deleted_at: Time.current)
          cart.update!(updated_at: 25.hours.ago)

          expect(Cart.abandoned).not_to include(cart)
        end

  test "returns abandoned carts" do
          cart = create(:cart)
          create(:cart_product, cart:)
          cart.update!(updated_at: 25.hours.ago)

          expect(Cart.abandoned).to include(cart)
        end
      end
    end

  context_ "#abandoned?" do
  test "returns false for a deleted cart" do
        cart = create(:cart)
        cart.mark_deleted!
        expect(cart.abandoned?).to be(false)
      end

  test "returns false if the cart was last updated more than a month ago" do
        cart = create(:cart, updated_at: 32.days.ago)
        expect(cart.abandoned?).to be(false)
      end

  test "returns false if the cart was last updated less than 24 hours ago" do
        cart = create(:cart, updated_at: 23.hours.ago)
        expect(cart.abandoned?).to be(false)
      end

  test "returns false if the cart has been sent an abandoned cart email" do
        cart = create(:cart)
        create(:cart_product, cart:)
        create(:sent_abandoned_cart_email, cart:)
        cart.update!(updated_at: 25.hours.ago)

        expect(cart.abandoned?).to be(false)
      end

  test "returns false if the cart has no alive cart products" do
        cart = create(:cart)
        create(:cart_product, cart:, deleted_at: Time.current)
        cart.update!(updated_at: 25.hours.ago)

        expect(cart.abandoned?).to be(false)
      end

  test "returns true" do
        cart = create(:cart)
        create(:cart_product, cart:)
        cart.update!(updated_at: 25.hours.ago)

        expect(cart.abandoned?).to be(true)
      end
    end

  context_ ".fetch_by" do
      let(:browser_guid) { SecureRandom.uuid }

  context_ "when user is present" do
  test "returns the alive cart for that user" do
          user = create(:user)
          create(:cart, user:, deleted_at: 1.hour.ago)
          create(:cart, :guest, browser_guid:)
          user_cart = create(:cart, user:, browser_guid:)

          expect(Cart.fetch_by(user:, browser_guid:)).to eq(user_cart)
          expect(Cart.fetch_by(user:, browser_guid: nil)).to eq(user_cart)
        end
      end

  context_ "when user is not present and browser_guid is present" do
        let!(:user_cart) { create(:cart, browser_guid:) }
        let!(:deleted_guest_cart) { create(:cart, :guest, browser_guid:, deleted_at: 1.hour.ago) }
        let!(:guest_cart) { create(:cart, :guest, browser_guid:) }

  test "returns the alive cart with the given browser_guid" do
          expect(Cart.fetch_by(user: nil, browser_guid:)).to eq(guest_cart)
        end
      end
    end
  end
end
