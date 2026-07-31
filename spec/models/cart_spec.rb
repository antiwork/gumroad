# frozen_string_literal: true

require "spec_helper"

describe Cart do
  describe "associations" do
    describe "#alive_cart_products" do
      it "returns only alive cart products" do
        cart = create(:cart)
        alive_cart_product = create(:cart_product, cart:)
        create(:cart_product, cart:, deleted_at: Time.current)
        expect(cart.alive_cart_products).to eq([alive_cart_product])
      end
    end
  end

  describe "callbacks" do
    it "assigns default discount codes after initialization" do
      cart = build(:cart)
      expect(cart.discount_codes).to eq([])
    end
  end

  describe "validations" do
    describe "discount codes" do
      context "when discount codes are not provided" do
        it "marks the cart as valid" do
          cart = build(:cart, discount_codes: [])
          expect(cart).to be_valid
        end
      end

      context "when discount codes are not an array" do
        it "marks the cart as invalid" do
          cart = build(:cart, discount_codes: {})
          expect(cart).to be_invalid
          expect(cart.errors.full_messages.join).to include("The property '#/' of type object did not match the following type: array")
        end
      end

      context "when required fields are missing from discount codes" do
        it "marks the cart as invalid" do
          cart = build(:cart, discount_codes: [{}])
          expect(cart).to be_invalid
          errors = cart.errors.full_messages.join("\n")
          expect(errors).to include("The property '#/0' did not contain a required property of 'code'")
          expect(errors).to include("The property '#/0' did not contain a required property of 'fromUrl'")
        end
      end

      context "when discount codes are valid" do
        it "marks the cart as valid" do
          cart = build(:cart, discount_codes: [{ code: "ABC123", fromUrl: false }, { code: "DEF456", fromUrl: true }])
          expect(cart).to be_valid
        end
      end
    end

    describe "alive carts per user" do
      context "when user is present" do
        it "validates the user only has one alive cart" do
          user = create(:user)
          first_cart = create(:cart, user:)
          second_cart = build(:cart, user:)
          expect(second_cart).to be_invalid
          expect(second_cart.errors.full_messages).to include("An alive cart already exists")
          first_cart.mark_deleted!
          expect(second_cart).to be_valid
        end
      end

      context "when browser_guid is present and user is not present" do
        it "validates that there is only one alive cart per browser_guid for a non-logged-in user" do
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

  describe "scopes" do
    describe "abandoned" do
      it "does not return deleted carts" do
        cart = create(:cart)
        cart.mark_deleted!
        expect(Cart.abandoned).not_to include(cart)
      end

      it "does not return carts that have been last updated more than a month ago" do
        cart = create(:cart, updated_at: 32.days.ago)
        expect(Cart.abandoned).not_to include(cart)
      end

      it "does not return carts that have been last updated less than 24 hours ago" do
        cart = create(:cart, updated_at: 23.hours.ago)
        expect(Cart.abandoned).not_to include(cart)
      end

      it "does not return carts that have been sent an abandoned cart email" do
        cart = create(:cart)
        create(:cart_product, cart:)
        create(:sent_abandoned_cart_email, cart:)
        cart.update!(updated_at: 25.hours.ago)

        expect(Cart.abandoned).not_to include(cart)
      end

      it "does not return carts that have no alive cart products" do
        cart = create(:cart)
        create(:cart_product, cart:, deleted_at: Time.current)
        cart.update!(updated_at: 25.hours.ago)

        expect(Cart.abandoned).not_to include(cart)
      end

      it "returns abandoned carts" do
        cart = create(:cart)
        create(:cart_product, cart:)
        cart.update!(updated_at: 25.hours.ago)

        expect(Cart.abandoned).to include(cart)
      end
    end
  end

  describe "#purchased_product_ids" do
    let(:product) { create(:product) }
    let(:other_product) { create(:product) }
    let(:buyer) { create(:user) }
    let(:cart) { create(:cart, user: buyer) }

    before do
      create(:cart_product, cart:, product:)
      create(:cart_product, cart:, product: other_product)
    end

    it "returns only the carted products the buyer has bought" do
      create(:purchase, link: product, email: buyer.email, purchaser: buyer)

      expect(cart.purchased_product_ids).to eq([product.id])
    end

    it "matches a purchase made under a differently-cased spelling of the cart's email" do
      cart.update!(user: nil, email: "Buyer@Example.com")
      create(:purchase, link: product, email: "buyer@example.com", purchaser: nil)

      expect(cart.purchased_product_ids).to eq([product.id])
    end

    it "matches a guest-checkout purchase made under the cart user's account email" do
      create(:purchase, link: product, email: buyer.email, purchaser: nil)

      expect(cart.purchased_product_ids).to eq([product.id])
    end

    it "matches a purchase made by the cart's user under a different email" do
      create(:purchase, link: product, email: "elsewhere@example.com", purchaser: buyer)

      expect(cart.purchased_product_ids).to eq([product.id])
    end

    it "ignores a purchase by the stale cart email when the cart belongs to a signed-in user" do
      # The mailer delivers to the account email only, so a leftover guest-session address on a
      # logged-in cart must not suppress anything — that address can belong to someone else.
      cart.update!(email: "previous-guest@example.com")
      create(:purchase, link: product, email: "previous-guest@example.com", purchaser: create(:user))

      expect(cart.purchased_product_ids).to be_empty
    end

    it "still suppresses on the account email when a stale cart email is present" do
      cart.update!(email: "previous-guest@example.com")
      create(:purchase, link: product, email: buyer.email, purchaser: buyer)

      expect(cart.purchased_product_ids).to eq([product.id])
    end

    it "ignores another buyer's purchase of the same product" do
      create(:purchase, link: product, email: "someone-else@example.com", purchaser: create(:user))

      expect(cart.purchased_product_ids).to be_empty
    end

    it "ignores a refunded purchase" do
      create(:purchase, link: product, email: buyer.email, purchaser: buyer, stripe_refunded: true)

      expect(cart.purchased_product_ids).to be_empty
    end

    it "ignores a charged-back purchase" do
      create(:purchase, link: product, email: buyer.email, purchaser: buyer, chargeback_date: 1.day.ago)

      expect(cart.purchased_product_ids).to be_empty
    end

    it "ignores a failed purchase" do
      create(:failed_purchase, link: product, email: buyer.email, purchaser: buyer)

      expect(cart.purchased_product_ids).to be_empty
    end

    it "ignores a gift bought for someone else" do
      create(:purchase, :gift_sender, link: product, email: buyer.email, purchaser: buyer)

      expect(cart.purchased_product_ids).to be_empty
    end

    it "counts a gift received" do
      create(:purchase, :gift_receiver, link: product, email: buyer.email, purchaser: buyer)

      expect(cart.purchased_product_ids).to eq([product.id])
    end

    it "counts a free purchase" do
      create(:free_purchase, link: product, email: buyer.email, purchaser: buyer)

      expect(cart.purchased_product_ids).to eq([product.id])
    end
  end

  describe "#purchased_product_ids for memberships and variants" do
    let(:buyer) { create(:user) }

    it "counts an active free trial" do
      purchase = create(:free_trial_membership_purchase, email: buyer.email, purchaser: buyer)
      cart = create(:cart, user: buyer)
      create(:cart_product, cart:, product: purchase.link)

      expect(cart.reload.purchased_product_ids).to eq([purchase.link.id])
    end

    it "does not count a membership whose subscription was deactivated" do
      purchase = create(:membership_purchase, email: buyer.email, purchaser: buyer)
      purchase.subscription.update!(deactivated_at: 1.day.ago)
      cart = create(:cart, user: buyer)
      create(:cart_product, cart:, product: purchase.link)

      expect(cart.reload.purchased_product_ids).to be_empty
    end

    it "counts the carted variant only when the purchase carries that same variant" do
      product = create(:product)
      category = create(:variant_category, link: product)
      owned_variant = create(:variant, variant_category: category)
      other_variant = create(:variant, variant_category: category)
      create(:purchase, link: product, email: buyer.email, purchaser: buyer, variant_attributes: [owned_variant])

      owned_cart = create(:cart, user: buyer)
      create(:cart_product, cart: owned_cart, product:, option: owned_variant)
      expect(owned_cart.reload.purchased_product_ids).to eq([product.id])

      other_cart = create(:cart, :guest, email: buyer.email)
      create(:cart_product, cart: other_cart, product:, option: other_variant)
      expect(other_cart.reload.purchased_product_ids).to be_empty
    end
  end

  describe ".purchased_product_ids_by_cart_id" do
    it "attributes each buyer's purchases to their own cart without querying per cart" do
      product = create(:product)
      buyer1 = create(:user)
      buyer2 = create(:user)
      cart1 = create(:cart, user: buyer1)
      cart2 = create(:cart, user: buyer2)
      create(:cart_product, cart: cart1, product:)
      create(:cart_product, cart: cart2, product:)
      create(:purchase, link: product, email: buyer1.email, purchaser: buyer1)

      purchase_queries = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        purchase_queries += 1 if payload[:sql].include?("FROM `purchases`")
      end
      begin
        result = Cart.purchased_product_ids_by_cart_id([cart1.reload, cart2.reload])
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      # Two statements per product-id slice (one per recipient column), not one per cart: the
      # abandoned-cart run passes a 500-cart batch through here.
      expect(purchase_queries).to eq(2)
      expect(result[cart1.id]).to eq([product.id])
      expect(result[cart2.id]).to be_empty
    end

    it "slices the product-id IN list so a large batch cannot fall off MySQL's range-optimizer cliff" do
      product = create(:product)
      buyer = create(:user)
      cart = create(:cart, user: buyer)
      create(:cart_product, cart:, product:)
      create(:purchase, link: product, email: buyer.email, purchaser: buyer)
      stub_const("Cart::PURCHASE_LOOKUP_IN_LIST_BATCH_SIZE", 1)

      expect(Cart.purchased_product_ids_by_cart_id([cart.reload])[cart.id]).to eq([product.id])
    end

    it "reads each cart's user from the preload instead of querying per cart" do
      product = create(:product)
      carts = 3.times.map do
        cart = create(:cart, user: create(:user))
        create(:cart_product, cart:, product:)
        cart
      end

      preloaded = Cart.includes(:alive_cart_products, :user).where(id: carts.map(&:id)).to_a
      user_queries = 0
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        user_queries += 1 if payload[:sql].include?("FROM `users`")
      end
      begin
        Cart.purchased_product_ids_by_cart_id(preloaded)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      # The job passes a 500-cart batch, so reading cart.user per cart here would be 500
      # round trips inside the loop.
      expect(user_queries).to eq(0)
    end

    it "raises the session statement budget for the lookup" do
      product = create(:product)
      cart = create(:cart, user: create(:user))
      create(:cart_product, cart:, product:)

      expect(WithMaxExecutionTime).to receive(:timeout_queries).with(seconds: Cart::PURCHASE_LOOKUP_TIME_BUDGET).and_call_original

      Cart.purchased_product_ids_by_cart_id([cart.reload])
    end
  end

  describe "#abandoned?" do
    it "returns false for a deleted cart" do
      cart = create(:cart)
      cart.mark_deleted!
      expect(cart.abandoned?).to be(false)
    end

    it "returns false if the cart was last updated more than a month ago" do
      cart = create(:cart, updated_at: 32.days.ago)
      expect(cart.abandoned?).to be(false)
    end

    it "returns false if the cart was last updated less than 24 hours ago" do
      cart = create(:cart, updated_at: 23.hours.ago)
      expect(cart.abandoned?).to be(false)
    end

    it "returns false if the cart has been sent an abandoned cart email" do
      cart = create(:cart)
      create(:cart_product, cart:)
      create(:sent_abandoned_cart_email, cart:)
      cart.update!(updated_at: 25.hours.ago)

      expect(cart.abandoned?).to be(false)
    end

    it "returns false if the cart has no alive cart products" do
      cart = create(:cart)
      create(:cart_product, cart:, deleted_at: Time.current)
      cart.update!(updated_at: 25.hours.ago)

      expect(cart.abandoned?).to be(false)
    end

    it "returns true" do
      cart = create(:cart)
      create(:cart_product, cart:)
      cart.update!(updated_at: 25.hours.ago)

      expect(cart.abandoned?).to be(true)
    end
  end

  describe ".fetch_by" do
    let(:browser_guid) { SecureRandom.uuid }

    context "when user is present" do
      it "returns the alive cart for that user" do
        user = create(:user)
        create(:cart, user:, deleted_at: 1.hour.ago)
        create(:cart, :guest, browser_guid:)
        user_cart = create(:cart, user:, browser_guid:)

        expect(Cart.fetch_by(user:, browser_guid:)).to eq(user_cart)
        expect(Cart.fetch_by(user:, browser_guid: nil)).to eq(user_cart)
      end
    end

    context "when user is not present and browser_guid is present" do
      let!(:user_cart) { create(:cart, browser_guid:) }
      let!(:deleted_guest_cart) { create(:cart, :guest, browser_guid:, deleted_at: 1.hour.ago) }
      let!(:guest_cart) { create(:cart, :guest, browser_guid:) }

      it "returns the alive cart with the given browser_guid" do
        expect(Cart.fetch_by(user: nil, browser_guid:)).to eq(guest_cart)
      end
    end
  end
end
