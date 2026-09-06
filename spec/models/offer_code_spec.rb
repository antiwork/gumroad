# frozen_string_literal: true

require "spec_helper"
require "shared_examples/max_purchase_count_concern"

describe OfferCode do
  before do
    MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
      create(:merchant_account, user: nil, charge_processor_merchant_id: "acct_#{SecureRandom.hex(8)}")
    @product = create(:product, user: create(:user), price_cents: 2000, price_currency_type: "usd")
  end

  it_behaves_like "MaxPurchaseCount concern", :offer_code

  describe "code validation" do
    describe "uniqueness" do
      describe "universal offer codes" do
        it "does not allow 2 live universal offer codes with same code" do
          create(:universal_offer_code, code: "off", user: @product.user)
          duplicate_offer_code = OfferCode.new(code: "off", universal: true, user: @product.user, amount_cents: 100, currency_type: "usd")

          expect(duplicate_offer_code).to_not be_valid
          expect(duplicate_offer_code.errors.full_messages).to eq(["Discount code must be unique."])
        end

        it "does not allow a universal offer code to have the same name as any product's offer code" do
          create(:offer_code, code: "off", user: @product.user, products: [@product])
          duplicate_offer_code = OfferCode.new(code: "off", universal: true, user: @product.user, amount_cents: 100, currency_type: "usd")

          expect(duplicate_offer_code).to_not be_valid
          expect(duplicate_offer_code.errors.full_messages).to eq(["Discount code must be unique."])
        end

        it "allows offer codes with same code if one of them is deleted" do
          old_code = create(:universal_offer_code, code: "off", user: @product.user)
          old_code.mark_deleted!
          live_offer_code = OfferCode.new(code: "off", universal: true, user: old_code.user, amount_cents: 100, currency_type: "usd")

          expect(live_offer_code).to be_valid
          expect { live_offer_code.save! }.to change { OfferCode.count }.by(1)
          # Make sure the validation does not prevent offer codes from being marked as deleted (deleted offer codes may have duplicate codes)
          live_offer_code.mark_deleted!
          expect(live_offer_code).to be_deleted
        end
      end

      describe "product-specific offer codes" do
        it "does not allow 2 live offer codes with same code" do
          create(:offer_code, code: "off", user: @product.user, products: [@product])
          duplicate_offer_code = OfferCode.new(code: "off", user: @product.user, products: [@product], amount_cents: 100, currency_type: "usd")

          expect(duplicate_offer_code).to_not be_valid
          expect(duplicate_offer_code.errors.full_messages).to eq(["Discount code must be unique."])
        end

        it "does not allow a product-specific offer code with the same code as the universal offer code" do
          create(:universal_offer_code, code: "off", user: @product.user)
          duplicate_offer_code = OfferCode.new(code: "off", user: @product.user, products: [@product], amount_cents: 100, currency_type: "usd")

          expect(duplicate_offer_code).to_not be_valid
          expect(duplicate_offer_code.errors.full_messages).to eq(["Discount code must be unique."])
        end

        it "allows offer codes with same code if one of them is deleted" do
          old_code = create(:offer_code, code: "off", products: [@product])
          old_code.mark_deleted!
          offer_code = OfferCode.new(code: "off", user: old_code.user, products: [@product], amount_cents: 100, currency_type: "usd")

          expect(offer_code).to be_valid
          expect { offer_code.save! }.to change { OfferCode.count }.by(1)
          offer_code.mark_deleted!
          expect(offer_code).to be_deleted
        end
      end
    end

    it "allows offer codes with alphanumeric characters, dashes, and underscores" do
      %w[100OFF 25discount sale50 ÕËëæç disc-50_100].each do |code|
        expect { create(:offer_code, products: [@product], code:) }.to change { OfferCode.count }.by(1)
      end
    end

    it "rejects offer codes with forbidden characters" do
      %w[100% #100OFF 100.OFF OFF@100].each do |code|
        offer_code = OfferCode.new(code:, products: [@product], amount_cents: 100, currency_type: "usd")

        expect(offer_code).to be_invalid
        expect(offer_code.errors.full_messages).to include("Discount code can only contain numbers, letters, dashes, and underscores.")
      end
    end

    it "strips lagging and leading whitespace from code" do
      [" foo", "bar ", "  baz  "].each do |code|
        offer_code = build(:offer_code, code:, products: [@product], amount_cents: 100, currency_type: "usd")

        expect(offer_code).to be_valid
        expect(offer_code.code).to eq code.strip
      end
    end
  end

  describe "#price_validation" do
    describe "percentage offer codes" do
      it "is valid if the price after discount is above the minimum purchase price" do
        expect { create(:percentage_offer_code, code: "oc1", products: [@product], amount_percentage: 50) }.to change { OfferCode.count }.by(1)
        expect { create(:percentage_offer_code, code: "oc2", products: [@product], amount_percentage: 100) }.to change { OfferCode.count }.by(1)
        expect { create(:percentage_offer_code, code: "oc3", products: [@product], amount_percentage: 5) }.to change { OfferCode.count }.by(1)
        expect { create(:percentage_offer_code, code: "oc4", products: [@product], amount_percentage: 0) }.to change { OfferCode.count }.by(1)
      end

      it "is not valid if the price after discount is below the minimum purchase price" do
        expect { create(:percentage_offer_code, products: [@product], amount_percentage: 99) }
          .to raise_error(ActiveRecord::RecordInvalid, "Validation failed: The price after discount for all of your products must be either $0 or at least $0.99.")
        expect { create(:percentage_offer_code, products: [@product], amount_percentage: 99) rescue nil }.to_not change { OfferCode.count }
      end

      it "is not valid if the percentage amount is outside 0-100 range" do
        expect { create(:percentage_offer_code, products: [@product], amount_percentage: 123) }
          .to raise_error(ActiveRecord::RecordInvalid, "Validation failed: Please enter a discount amount that is 100% or less.")
        expect { create(:percentage_offer_code, products: [@product], amount_percentage: 123) rescue nil }.to_not change { OfferCode.count }
        expect { create(:percentage_offer_code, products: [@product], amount_percentage: -100) rescue nil }.to_not change { OfferCode.count }
      end
    end

    describe "cents offer codes" do
      it "is valid if the amount off is >= 0" do
        expect { create(:offer_code, code: "oc1", products: [@product], amount_cents: 1000) }.to change { OfferCode.count }.by(1)
        expect { create(:offer_code, code: "oc2", products: [@product], amount_cents: 2000) }.to change { OfferCode.count }.by(1)
        expect { create(:offer_code, code: "oc3", products: [@product], amount_cents: 50) }.to change { OfferCode.count }.by(1)
        expect { create(:offer_code, code: "oc4", products: [@product], amount_cents: 10_000) }.to change { OfferCode.count }.by(1)
        expect { create(:offer_code, code: "oc5", products: [@product], amount_cents: 0) }.to change { OfferCode.count }.by(1)
      end

      it "is not valid if the amount off is negative" do
        expect { create(:offer_code, products: [@product], amount_cents: -2000) rescue nil }.to_not change { OfferCode.count }
      end

      it "is not valid if the price after discount is less than the minimum purchase price" do
        expect { create(:offer_code, products: [@product], amount_cents: 1999.5) }
          .to raise_error(ActiveRecord::RecordInvalid, "Validation failed: The price after discount for all of your products must be either $0 or at least $0.99.")
        expect { create(:offer_code, products: [@product], amount_cents: 1999.5) rescue nil }.to_not change { OfferCode.count }
        expect { create(:offer_code, products: [@product], amount_cents: -2000) rescue nil }.to_not change { OfferCode.count }
      end
    end

    describe "offer codes with neither a percentage nor a cents amount" do
      it "rejects the code with a validation error instead of raising" do
        expect { create(:offer_code, products: [@product], amount_percentage: nil, amount_cents: nil) }
          .to raise_error(ActiveRecord::RecordInvalid, /Please enter a discount amount\./)
        expect { create(:offer_code, products: [@product], amount_percentage: nil, amount_cents: nil) rescue nil }.to_not change { OfferCode.count }
      end
    end

    describe "universal offer codes" do
      before do
        create(:product, user: @product.user, price_cents: 1000, price_currency_type: "usd")
      end

      it "persists valid offer codes" do
        expect { create(:universal_offer_code, code: "oc1", user: @product.user, amount_cents: 1000) }.to change { OfferCode.count }.by(1)
        expect { create(:universal_offer_code, code: "oc2", user: @product.user, amount_cents: 500) }.to change { OfferCode.count }.by(1)
        expect { create(:universal_offer_code, code: "oc3", user: @product.user, amount_cents: 2000) }.to change { OfferCode.count }.by(1)
        expect { create(:universal_offer_code, code: "oc4", user: @product.user, amount_cents: 10_000) }.to change { OfferCode.count }.by(1)
        expect { create(:universal_offer_code, code: "oc5", user: @product.user, amount_percentage: 50, amount_cents: nil) }.to change { OfferCode.count }.by(1)
      end

      it "does not persist invalid offer codes" do
        expect { create(:universal_offer_code, user: @product.user, amount_cents: -2000) rescue nil }.to_not change { OfferCode.count }
        expect { create(:universal_offer_code, user: @product.user, amount_percentage: 99, amount_cents: nil) rescue nil }.to_not change { OfferCode.count }
      end

      it "persists offer codes whose discount is only invalid for excluded products" do
        cheap_product = create(:product, user: @product.user, price_cents: 100)

        expect { create(:universal_offer_code, code: "oc6", user: @product.user, amount_percentage: 50, amount_cents: nil) rescue nil }.to_not change { OfferCode.count }
        expect { create(:universal_offer_code, code: "oc7", user: @product.user, amount_percentage: 50, amount_cents: nil, excluded_products: [cheap_product]) }.to change { OfferCode.count }.by(1)
      end

      context "different currencies for products" do
        before do
          @euro_product = create(:product, user: @product.user, price_cents: 500, price_currency_type: "eur")
        end

        it "persists valid offer codes" do
          expect { create(:universal_offer_code, code: "uoc1", user: @product.user, amount_cents: 1000, currency_type: "usd") }.to change { OfferCode.count }.by(1)
          expect { create(:universal_offer_code, code: "uoc2", user: @product.user, amount_cents: 5000, currency_type: "usd") }.to change { OfferCode.count }.by(1)
          expect { create(:universal_offer_code, code: "uoc3", user: @product.user, amount_cents: 500, currency_type: "eur") }.to change { OfferCode.count }.by(1)
          expect { create(:universal_offer_code, code: "uoc4", user: @product.user, amount_cents: 1000, currency_type: "eur") }.to change { OfferCode.count }.by(1)
          expect { create(:universal_offer_code, code: "uoc5", user: @product.user, amount_percentage: 50, amount_cents: nil) }.to change { OfferCode.count }.by(1)
        end

        it "does not persist invalid offer codes" do
          expect { create(:universal_offer_code, code: "uoc", user: @product.user, amount_percentage: 99, amount_cents: nil) rescue nil }.to_not change { OfferCode.count }
        end
      end
    end

    context "the offer code applies to a membership product" do
      let(:offer_code) { create(:offer_code, products: [create(:membership_product_with_preset_tiered_pricing)], amount_cents: 300) }

      context "the offer code is fixed-duration" do
        before do
          offer_code.duration_in_billing_cycles = 1
        end

        context "the offer code discounts the membership to free" do
          it "adds an error" do
            expect(offer_code).to_not be_valid
            expect(offer_code.errors.full_messages.first).to eq("A fixed-duration discount code cannot be used to make a membership product temporarily free. Please add a free trial to your membership instead.")
          end
        end

        context "the offer code doesn't discount the membership to free" do
          before do
            offer_code.update!(amount_cents: 100)
          end

          it "doesn't add an error" do
            expect(offer_code).to be_valid
          end
        end

        context "when a once-per-cart code requires multiple units" do
          before do
            offer_code.once_per_cart = true
            offer_code.minimum_quantity = 2
          end

          it "validates against the eligible cart price" do
            expect(offer_code).to be_valid
          end
        end
      end

      context "the offer code is not fixed duration" do
        context "the offer code discounts the membership to free" do
          it "doesn't add an error" do
            expect(offer_code).to be_valid
          end
        end

        context "the offer code doesn't discount the membership to free" do
          before do
            offer_code.update!(amount_cents: 100)
          end

          it "doesn't add an error" do
            expect(offer_code).to be_valid
          end
        end
      end
    end
  end

  describe "excluded products validation" do
    let(:excluded_product) { create(:product, user: @product.user) }

    it "allows excluded products on universal offer codes" do
      offer_code = build(:universal_offer_code, user: @product.user, excluded_products: [excluded_product])
      expect(offer_code).to be_valid
    end

    it "disallows excluded products on product-specific offer codes" do
      offer_code = build(:offer_code, user: @product.user, products: [@product], excluded_products: [excluded_product])
      expect(offer_code).not_to be_valid
      expect(offer_code.errors.full_messages).to include("Products can only be excluded from discounts that apply to all products.")
    end

    it "disallows excluding a product whose default discount is this offer code" do
      offer_code = create(:universal_offer_code, user: @product.user)
      excluded_product.update!(default_offer_code_id: offer_code.id)

      expect(offer_code.update(excluded_products: [excluded_product])).to eq(false)
      expect(offer_code.errors.full_messages).to include("This discount code is the default discount for one or more of the excluded products. Please remove it from those products before excluding them.")
      expect(offer_code.reload.excluded_products).to eq([])
    end
  end

  describe "default discount applicability validation" do
    let(:other_product) { create(:product, user: @product.user) }
    let(:offer_code) { create(:offer_code, user: @product.user, products: [@product, other_product]) }

    it "disallows removing a product whose default discount is this offer code" do
      @product.update!(default_offer_code_id: offer_code.id)

      expect(offer_code.update(products: [other_product])).to eq(false)
      expect(offer_code.errors.full_messages).to include("This discount code is the default discount for “#{@product.name}”. Please remove it from that product before removing it from the discount.")
      expect(offer_code.reload.products).to match_array([@product, other_product])
    end

    it "disallows removing all products when one of them uses this offer code as its default discount" do
      @product.update!(default_offer_code_id: offer_code.id)

      expect(offer_code.update(products: [])).to eq(false)
      expect(offer_code.errors.full_messages).to include("This discount code is the default discount for “#{@product.name}”. Please remove it from that product before removing it from the discount.")
      expect(offer_code.reload.products).to match_array([@product, other_product])
    end

    it "allows removing a product that doesn't use this offer code as its default discount" do
      @product.update!(default_offer_code_id: nil)

      expect(offer_code.update(products: [other_product])).to eq(true)
      expect(offer_code.reload.products).to eq([other_product])
    end

    it "allows removing a deleted product that uses this offer code as its default discount" do
      @product.update!(default_offer_code_id: offer_code.id)
      @product.update!(deleted_at: Time.current)

      expect(offer_code.update(products: [other_product])).to eq(true)
      expect(offer_code.reload.products).to eq([other_product])
    end

    it "allows saving while an attached product uses this offer code as its default discount" do
      @product.update!(default_offer_code_id: offer_code.id)

      expect(offer_code.update(name: "New name")).to eq(true)
    end

    it "allows updating a universal offer code that is a product's default discount" do
      universal_offer_code = create(:universal_offer_code, user: @product.user)
      @product.update!(default_offer_code_id: universal_offer_code.id)

      expect(universal_offer_code.update(name: "New name")).to eq(true)
    end

    it "disallows moving a universal offer code to a currency a defaulting product doesn't use" do
      universal_offer_code = create(:universal_offer_code, user: @product.user, amount_cents: nil, amount_percentage: 50, currency_type: nil)
      @product.update!(default_offer_code_id: universal_offer_code.id)

      expect(universal_offer_code.update(amount_percentage: nil, amount_cents: 100, currency_type: "eur")).to eq(false)
      expect(universal_offer_code.errors.full_messages).to include("This discount code is the default discount for “#{@product.name}”, which uses a different currency. Please remove it from that product before changing the discount's currency.")
      expect(universal_offer_code.reload.currency_type).to eq(nil)
    end

    it "allows updating a universal percentage offer code that is a product's default discount" do
      universal_offer_code = create(:universal_offer_code, user: @product.user, amount_cents: nil, amount_percentage: 50, currency_type: nil)
      @product.update!(default_offer_code_id: universal_offer_code.id)

      expect(universal_offer_code.update(name: "New name")).to eq(true)
    end

    it "doesn't prevent creating an offer code while products without a default discount exist" do
      expect(@product.default_offer_code_id).to be_nil

      expect { create(:offer_code, user: @product.user, products: [other_product]) }.to change { OfferCode.count }.by(1)
    end

    it "allows unrelated edits while a default detached before this guard existed" do
      @product.update!(default_offer_code_id: offer_code.id)
      # The state Onetime::ClearDetachedDefaultOfferCodes exists to clear: the
      # product still defaults to the code but is no longer in its list. Direct
      # collection mutation never saves the owner, so no guard saw it.
      offer_code.products.delete(@product)

      expect(offer_code.reload.update(name: "New name")).to eq(true)
      expect(offer_code.update(valid_at: 1.day.ago, expires_at: 30.days.from_now)).to eq(true)
    end

    it "allows an edit that removes and re-adds the defaulting product" do
      @product.update!(default_offer_code_id: offer_code.id)

      offer_code.products.delete(@product)
      offer_code.products << @product

      expect(offer_code.save).to eq(true)
      expect(offer_code.reload.products).to match_array([@product, other_product])
    end

    it "allows a retry on the same instance once the seller clears the default" do
      @product.update!(default_offer_code_id: offer_code.id)
      expect(offer_code.update(products: [other_product])).to eq(false)

      @product.update!(default_offer_code_id: nil)

      expect(offer_code.update(products: [other_product])).to eq(true)
    end

    it "still blocks removing another product while a pre-existing detached default is present" do
      third_product = create(:product, user: @product.user)
      @product.update!(name: "Stale default")
      other_product.update!(name: "Actively removed")
      offer_code.update!(products: [@product, other_product, third_product])
      @product.update!(default_offer_code_id: offer_code.id)
      offer_code.products.delete(@product)
      other_product.update!(default_offer_code_id: offer_code.id)

      expect(offer_code.reload.update(products: [third_product])).to eq(false)
      # Only the product this edit removed is named; the stale one is ignored.
      expect(offer_code.errors.full_messages).to eq(["This discount code is the default discount for “Actively removed”. Please remove it from that product before removing it from the discount."])
    end

    it "names several removed products and counts the rest" do
      products = Array.new(5) { create(:product, user: @product.user) }
      offer_code.update!(products:)
      products.each { _1.update!(default_offer_code_id: offer_code.id) }

      expect(offer_code.update(products: [])).to eq(false)
      message = offer_code.errors.full_messages.first
      expect(message).to include("and 2 others")
      expect(message.scan("“").size).to eq(3)
    end

    it "blocks a universal code turning product-specific while a defaulting product is left out" do
      universal_offer_code = create(:universal_offer_code, user: @product.user)
      @product.update!(default_offer_code_id: universal_offer_code.id)

      expect(universal_offer_code.update(universal: false, products: [other_product])).to eq(false)
      expect(universal_offer_code.errors.full_messages).to include("This discount code is the default discount for “#{@product.name}”. Please remove it from that product before removing it from the discount.")
    end

    it "allows a universal code turning product-specific when it keeps the defaulting product" do
      universal_offer_code = create(:universal_offer_code, user: @product.user)
      @product.update!(default_offer_code_id: universal_offer_code.id)

      expect(universal_offer_code.update(universal: false, products: [@product])).to eq(true)
    end
  end

  describe "a product currency change detaching a universal default discount" do
    let(:universal_offer_code) { create(:universal_offer_code, user: @product.user, currency_type: "usd") }

    it "clears the default in the same write rather than leaving a discount checkout refuses" do
      @product.update!(default_offer_code_id: universal_offer_code.id)

      @product.update!(price_currency_type: "eur", price_range: "10")

      expect(@product.reload.default_offer_code_id).to be_nil
      expect(@product.default_offer_code_detached?).to eq(false)
    end

    it "leaves the universal code editable afterwards" do
      @product.update!(default_offer_code_id: universal_offer_code.id)
      @product.update!(price_currency_type: "eur", price_range: "10")

      expect(universal_offer_code.reload.update(name: "New name")).to eq(true)
    end

    it "leaves the default alone when the currency is not changing" do
      @product.update!(default_offer_code_id: universal_offer_code.id)

      # No currency change, so the repair must not run at all.
      expect_any_instance_of(Link).not_to receive(:clear_detached_default_offer_code)
      @product.update!(name: "Renamed")

      expect(@product.reload.default_offer_code_id).to eq(universal_offer_code.id)
    end

    it "keeps a product-specific default, which applies regardless of currency" do
      specific = create(:offer_code, user: @product.user, products: [@product], amount_cents: 100)
      @product.update!(default_offer_code_id: specific.id)

      @product.update!(price_currency_type: "eur", price_range: "10")

      expect(@product.reload.default_offer_code_id).to eq(specific.id)
    end

    it "keeps the default when duplicating a product in a non-default currency" do
      # A duplicate reports every attribute as changed, and its offer-code join
      # rows are copied only after the first save.
      @product.update!(price_currency_type: "eur", price_range: "10")
      specific = create(:offer_code, user: @product.user, products: [@product], amount_cents: 100, currency_type: "eur")
      @product.update!(default_offer_code_id: specific.id)

      duplicate = ProductDuplicatorService.new(@product.id).duplicate

      expect(duplicate.reload.default_offer_code_id).to eq(specific.id)
    end

    it "keeps a percentage universal default, which applies to every currency" do
      percentage_code = create(:universal_offer_code, user: @product.user, amount_cents: nil, amount_percentage: 50, currency_type: nil)
      @product.update!(default_offer_code_id: percentage_code.id)

      @product.update!(price_currency_type: "eur", price_range: "10")

      expect(@product.reload.default_offer_code_id).to eq(percentage_code.id)
    end
  end

  describe "repairing detached defaults after concurrent edits" do
    let(:other_product) { create(:product, user: @product.user) }
    let(:offer_code) { create(:offer_code, user: @product.user, products: [@product, other_product]) }

    it "clears a default assigned concurrently with the edit that detached it" do
      @product.update!(default_offer_code_id: offer_code.id)
      # This edit's validation read the defaults before the concurrent
      # assignment landed; skip it to reproduce that stale read.
      allow_any_instance_of(OfferCode).to receive(:validate_default_discount_remains_applicable)

      offer_code.update!(products: [other_product])

      expect(@product.reload.default_offer_code_id).to be_nil
    end

    it "clears a default excluded concurrently from a universal code" do
      universal_offer_code = create(:universal_offer_code, user: @product.user)
      @product.update!(default_offer_code_id: universal_offer_code.id)
      allow_any_instance_of(OfferCode).to receive(:validate_excluded_products)

      universal_offer_code.update!(excluded_products: [@product])

      expect(@product.reload.default_offer_code_id).to be_nil
    end

    it "skips the sweep for edits that can't affect applicability" do
      expect(offer_code).not_to receive(:repair_detached_default_discounts)

      offer_code.update!(max_purchase_count: 5)
    end

    it "leaves a default reattached between selection and the clearing write" do
      @product.update!(default_offer_code_id: offer_code.id)
      offer_code.products.delete(@product)

      # Stand in for a concurrent request that re-adds the product after this
      # sweep has already decided the default is detached.
      allow(Link).to receive(:where).and_wrap_original do |original, *args|
        relation = original.call(*args)
        if args.first.is_a?(Hash) && args.first[:id].is_a?(Array)
          offer_code.products << @product unless offer_code.products.reload.include?(@product)
        end
        relation
      end

      offer_code.send(:repair_detached_default_discounts)

      expect(@product.reload.default_offer_code_id).to eq(offer_code.id)
    end

    # Pins pre-existing behaviour rather than a change here: the sweep reads the
    # join table, so a delete that never saved the code is still seen.
    it "clears a default detached by a direct products.delete" do
      @product.update!(default_offer_code_id: offer_code.id)

      offer_code.products.delete(@product)
      offer_code.send(:repair_detached_default_discounts)

      expect(@product.reload.default_offer_code_id).to be_nil
    end
  end

  describe ".with_detached_default_offer_code" do
    # The scope is a SQL mirror of Link#default_offer_code_detached?; if the two
    # ever disagree the repairs either miss rows or clear valid defaults.
    def expect_scope_to_agree_with_predicate(product)
      product.reload
      by_sql = Link.where(id: product.id).with_detached_default_offer_code.exists?
      expect(by_sql).to eq(product.default_offer_code_detached?)
      by_sql
    end

    it "agrees with the Ruby predicate for an attached product-specific default" do
      code = create(:offer_code, user: @product.user, products: [@product])
      @product.update!(default_offer_code_id: code.id)

      expect(expect_scope_to_agree_with_predicate(@product)).to eq(false)
    end

    it "agrees when the product was removed from a product-specific code" do
      other = create(:product, user: @product.user)
      code = create(:offer_code, user: @product.user, products: [@product, other])
      @product.update!(default_offer_code_id: code.id)
      code.products.delete(@product)

      expect(expect_scope_to_agree_with_predicate(@product)).to eq(true)
    end

    it "agrees when the code was soft-deleted" do
      code = create(:offer_code, user: @product.user, products: [@product])
      @product.update!(default_offer_code_id: code.id)
      # validate_not_used_as_default_discount blocks deleting a code in use, so
      # this shape only exists as legacy data predating that guard.
      code.update_column(:deleted_at, Time.current)

      expect(expect_scope_to_agree_with_predicate(@product)).to eq(true)
    end

    it "agrees when the code carries no code string" do
      code = create(:offer_code, user: @product.user, products: [@product])
      @product.update!(default_offer_code_id: code.id)
      code.update_column(:code, nil)

      expect(expect_scope_to_agree_with_predicate(@product)).to eq(true)
    end

    it "agrees for a universal code in a different currency" do
      code = create(:universal_offer_code, user: @product.user, currency_type: "usd")
      @product.update!(default_offer_code_id: code.id)
      @product.update_column(:price_currency_type, "eur")

      expect(expect_scope_to_agree_with_predicate(@product)).to eq(true)
    end

    it "agrees for a percentage universal code with no currency" do
      code = create(:universal_offer_code, user: @product.user, amount_cents: nil, amount_percentage: 50, currency_type: nil)
      @product.update!(default_offer_code_id: code.id)
      @product.update_column(:price_currency_type, "eur")

      expect(expect_scope_to_agree_with_predicate(@product)).to eq(false)
    end

    it "agrees when a universal code excludes the product" do
      code = create(:universal_offer_code, user: @product.user, currency_type: nil)
      @product.update!(default_offer_code_id: code.id)
      code.excluded_products << @product

      expect(expect_scope_to_agree_with_predicate(@product)).to eq(true)
    end

    it "agrees when there is no default at all" do
      expect(expect_scope_to_agree_with_predicate(@product)).to eq(false)
    end
  end

  describe "validity dates validation" do
    context "when the start date is before the expiration date" do
      let(:offer_code) { build(:offer_code, valid_at: 2.days.ago, expires_at: 1.day.ago) }

      it "doesn't add an error" do
        expect(offer_code.valid?).to eq(true)
      end
    end

    context "when the expiration date is before the start date" do
      let(:offer_code) { build(:offer_code, valid_at: 1.day.ago, expires_at: 2.days.ago) }

      it "adds an error" do
        expect(offer_code.valid?).to eq(false)
        expect(offer_code.errors.full_messages.first).to eq("The discount code's start date must be earlier than its end date.")
      end
    end

    context "when the start date is unset and the expiration date is set" do
      let(:offer_code) { build(:offer_code, expires_at: 1.day.ago) }

      it "adds an error" do
        expect(offer_code.valid?).to eq(false)
        expect(offer_code.errors.full_messages.first).to eq("The discount code's start date must be earlier than its end date.")
      end
    end
  end

  describe "currency type validation" do
    context "percentage offer codes" do
      let(:usd_product) { create(:product, user: @product.user, price_cents: 1000, price_currency_type: "usd") }
      let(:eur_product) { create(:product, user: @product.user, price_cents: 800, price_currency_type: "eur") }

      context "when the offer code is a percentage discount" do
        it "doesn't validate currency type for percentage discounts" do
          offer_code = build(:percentage_offer_code, products: [usd_product], amount_percentage: 50)
          expect(offer_code).to be_valid
        end

        it "allows percentage discounts on products with different currencies" do
          offer_code = build(:percentage_offer_code, products: [usd_product, eur_product], amount_percentage: 25)
          expect(offer_code).to be_valid
        end
      end
    end

    context "cents offer codes" do
      let(:usd_product) { create(:product, user: @product.user, price_cents: 1000, price_currency_type: "usd") }
      let(:eur_product) { create(:product, user: @product.user, price_cents: 800, price_currency_type: "eur") }
      let(:gbp_product) { create(:product, user: @product.user, price_cents: 900, price_currency_type: "gbp") }

      context "when the currency types match" do
        it "is valid for USD products with USD offer code" do
          offer_code = build(:offer_code, products: [usd_product], amount_cents: 200, currency_type: "usd")
          expect(offer_code).to be_valid
        end

        it "is valid for EUR products with EUR offer code" do
          offer_code = build(:offer_code, products: [eur_product], amount_cents: 150, currency_type: "eur")
          expect(offer_code).to be_valid
        end

        it "is valid for multiple products with same currency type" do
          usd_product2 = create(:product, user: @product.user, price_cents: 1500, price_currency_type: "usd")
          offer_code = build(:offer_code, products: [usd_product, usd_product2], amount_cents: 300, currency_type: "usd")
          expect(offer_code).to be_valid
        end
      end

      context "when the currency types don't match" do
        it "adds an error for USD product with EUR offer code" do
          offer_code = build(:offer_code, products: [usd_product], amount_cents: 200, currency_type: "eur")
          expect(offer_code).to_not be_valid
          expect(offer_code.errors.full_messages).to include("This discount code uses EUR but the product uses USD. Please change the discount code to use the same currency as the product.")
        end

        it "adds an error for EUR product with GBP offer code" do
          offer_code = build(:offer_code, products: [eur_product], amount_cents: 150, currency_type: "gbp")
          expect(offer_code).to_not be_valid
          expect(offer_code.errors.full_messages).to include("This discount code uses GBP but the product uses EUR. Please change the discount code to use the same currency as the product.")
        end

        it "adds an error when products have mixed currencies" do
          offer_code = build(:offer_code, products: [usd_product, eur_product], amount_cents: 200, currency_type: "usd")
          expect(offer_code).to_not be_valid
          expect(offer_code.errors.full_messages).to include("This discount code uses USD but the product uses EUR. Please change the discount code to use the same currency as the product.")
        end
      end

      context "universal offer codes" do
        it "is valid for universal offer codes with currency type specified" do
          offer_code = build(:universal_offer_code, user: @product.user, amount_cents: 500, currency_type: "usd", universal: true)
          expect(offer_code).to be_valid
        end

        it "is valid for universal percentage offer codes without currency type" do
          offer_code = build(:universal_offer_code, user: @product.user, amount_percentage: 25, universal: true)
          expect(offer_code).to be_valid
        end
      end
    end
  end

  describe "#amount_off" do
    describe "percentage offer codes" do
      it "correctly calculates the amount off" do
        zero_off = create(:percentage_offer_code, code: "ZERO_OFF", products: [@product], amount_percentage: 0)
        expect(zero_off.amount_off(@product.price_cents)).to eq 0

        ten_off = create(:percentage_offer_code, code: "TEN_OFF", products: [@product], amount_percentage: 10)
        expect(ten_off.amount_off(@product.price_cents)).to eq 200

        fifty_off = create(:percentage_offer_code, code: "FIFTY_OFF", products: [@product], amount_percentage: 50)
        expect(fifty_off.amount_off(@product.price_cents)).to eq 1000

        hundred_off = create(:percentage_offer_code, code: "FREE", products: [@product], amount_percentage: 100)
        expect(hundred_off.amount_off(@product.price_cents)).to eq 2000
      end

      it "rounds the amount off" do
        product = create(:product, price_cents: 599, price_currency_type: "usd")
        offer_code = create(:percentage_offer_code, products: [product], amount_percentage: 50)
        expect(offer_code.amount_off(product.price_cents)).to eq 300

        offer_code.update!(amount_percentage: 70)
        expect(offer_code.amount_off(1395)).to eq 976
      end
    end

    describe "cents offer codes" do
      it "correctly calculates the amount off" do
        offer_code_1 = create(:offer_code, code: "1000_OFF", products: [@product], amount_cents: 1000)
        expect(offer_code_1.amount_off(@product.price_cents)).to eq 1000

        offer_code_2 = create(:offer_code, code: "500_OFF", products: [@product], amount_cents: 500)
        expect(offer_code_2.amount_off(@product.price_cents)).to eq 500

        offer_code_3 = create(:offer_code, code: "2000_OFF", products: [@product], amount_cents: 2000)
        expect(offer_code_3.amount_off(@product.price_cents)).to eq 2000
      end
    end

    it "returns 0 when neither a cents amount nor a percentage is set" do
      expect(OfferCode.new(amount_percentage: nil, amount_cents: nil).amount_off(@product.price_cents)).to eq 0
    end
  end

  describe "#original_price" do
    it "returns the original price for a percentage offer code" do
      offer_code = create(:percentage_offer_code, products: [@product], amount_percentage: 20)

      expect(offer_code.original_price(800)).to eq 1000
      expect(offer_code.original_price(199)).to eq 249
    end

    it "returns the original price for a cents offer code" do
      offer_code = create(:offer_code, products: [@product], amount_cents: 300)

      expect(offer_code.original_price(1000)).to eq 1300
    end

    it "returns nil for a 100% off offer code" do
      offer_code = create(:percentage_offer_code, products: [@product], amount_percentage: 100)

      expect(offer_code.original_price(0)).to eq nil
      expect(offer_code.original_price(100)).to eq nil
    end
  end

  describe "#as_json" do
    describe "percentage offer codes" do
      before do
        @offer_code = create(:percentage_offer_code, products: [@product], amount_percentage: 50)
      end

      it "returns percent_off and not amount_cents" do
        params = @offer_code.as_json

        expect(params[:percent_off]).to eq 50
        expect(params[:amount_cents]).to eq nil
      end
    end

    describe "cents offer codes" do
      before do
        @offer_code = create(:offer_code, products: [@product], amount_cents: 1000)
      end

      it "returns amount_cents and not percent_off" do
        params = @offer_code.as_json

        expect(params[:amount_cents]).to eq 1000
        expect(params[:percent_off]).to eq nil
      end
    end
  end

  describe "#quantity_left" do
    let(:offer_code) { create(:universal_offer_code, user: @product.user, max_purchase_count: 10) }
    let(:membership) { create(:membership_product, user: offer_code.user) }

    it "counts free trial purchases" do
      product = create(:membership_product, :with_free_trial_enabled, user: offer_code.user)
      create(:free_trial_membership_purchase, link: product, offer_code:, seller: offer_code.user)

      expect(offer_code.quantity_left).to eq offer_code.max_purchase_count - 1
    end

    it "counts preorder purchases" do
      create(:preorder_authorization_purchase, link: @product, offer_code:, seller: offer_code.user)

      expect(offer_code.quantity_left).to eq offer_code.max_purchase_count - 1
    end

    it "counts original subscription purchases" do
      create(:membership_purchase, link: membership, offer_code:, seller: offer_code.user)

      expect(offer_code.quantity_left).to eq offer_code.max_purchase_count - 1
    end

    it "excludes other purchases" do
      create(:recurring_membership_purchase, link: membership, offer_code:, is_original_subscription_purchase: false)
      create(:membership_purchase, link: membership, offer_code:, is_archived_original_subscription_purchase: true)
      create(:failed_purchase, link: @product, offer_code:, seller: @product.user)
      create(:test_purchase, link: @product, offer_code:, seller: @product.user)

      expect(offer_code.quantity_left).to eq offer_code.max_purchase_count
    end

    describe "universal offer codes" do
      let(:offer_code) { create(:universal_offer_code, user: @product.user, amount_percentage: 100, amount_cents: nil, currency_type: @product.price_currency_type, max_purchase_count: 10) }

      it "counts successful purchases" do
        create(:purchase, link: @product, offer_code:, seller: @product.user, price_cents: @product.price_cents)

        expect(offer_code.quantity_left).to eq offer_code.max_purchase_count - 1
      end

      it "sums the quantities of applicable purchases" do
        create(:purchase, link: @product, offer_code:, seller: @product.user, price_cents: @product.price_cents * 10, quantity: 10)

        expect(offer_code.quantity_left).to eq 0
      end

      it "counts a multi-quantity purchase once for a fixed order-level discount" do
        offer_code.update!(amount_percentage: nil, amount_cents: 100, once_per_cart: true)
        purchase = create(:purchase, link: @product, offer_code:, seller: @product.user, price_cents: @product.price_cents * 10, quantity: 10)
        purchase.create_purchase_offer_code_discount!(offer_code:, offer_code_amount: 100, offer_code_is_percent: false,
                                                      once_per_cart: true, pre_discount_minimum_price_cents: @product.price_cents)

        expect(offer_code.quantity_left).to eq offer_code.max_purchase_count - 1
      end

      it "counts one allocation across successful subscription restart fragments" do
        offer_code.update!(amount_percentage: nil, amount_cents: 100, once_per_cart: true, max_purchase_count: 1)
        subscription = create(:subscription, link: membership)
        updated_original = create(
          :purchase,
          link: membership,
          seller: offer_code.user,
          subscription:,
          offer_code:,
          is_original_subscription_purchase: true,
          is_updated_original_subscription_purchase: true
        )
        recurring_fragment = create(
          :purchase,
          link: membership,
          seller: offer_code.user,
          subscription:,
          offer_code:,
          is_original_subscription_purchase: false,
          is_upgrade_purchase: true
        )
        allocation_id = SecureRandom.uuid
        [updated_original, recurring_fragment].each do |purchase|
          purchase.create_purchase_offer_code_discount!(
            offer_code:,
            offer_code_amount: 100,
            offer_code_is_percent: false,
            once_per_cart: true,
            once_per_cart_allocation_id: allocation_id,
            pre_discount_minimum_price_cents: membership.price_cents
          )
        end

        expect(offer_code.quantity_left).to eq(0)
        expect(described_class.uses_left_by_id([offer_code])).to eq(offer_code.id => false)
      end

      it "can exclude a completed allocation when validating another fragment" do
        offer_code.update!(amount_percentage: nil, amount_cents: 100, once_per_cart: true, max_purchase_count: 1)
        allocation_id = SecureRandom.uuid
        purchase = create(:purchase, link: @product, offer_code:, seller: offer_code.user)
        purchase.create_purchase_offer_code_discount!(
          offer_code:,
          offer_code_amount: 100,
          offer_code_is_percent: false,
          once_per_cart: true,
          once_per_cart_allocation_id: allocation_id,
          pre_discount_minimum_price_cents: @product.price_cents
        )

        expect(offer_code.quantity_left).to eq(0)
        expect(offer_code.quantity_left(excluding_once_per_cart_allocation_ids: [allocation_id])).to eq(1)
        expect(offer_code.quantity_left(excluding_once_per_cart_allocation_ids: [SecureRandom.uuid])).to eq(0)
      end

      it "does not count an archived subscription restart allocation" do
        offer_code.update!(amount_percentage: nil, amount_cents: 100, once_per_cart: true, max_purchase_count: 1)
        subscription = create(:subscription, link: membership)
        purchase = create(
          :purchase,
          link: membership,
          seller: offer_code.user,
          subscription:,
          offer_code:,
          is_original_subscription_purchase: true,
          is_updated_original_subscription_purchase: true,
          is_archived_original_subscription_purchase: true
        )
        purchase.create_purchase_offer_code_discount!(
          offer_code:,
          offer_code_amount: 100,
          offer_code_is_percent: false,
          once_per_cart: true,
          once_per_cart_allocation_id: SecureRandom.uuid,
          pre_discount_minimum_price_cents: membership.price_cents
        )

        expect(offer_code.quantity_left).to eq(1)
        expect(described_class.uses_left_by_id([offer_code])).to eq(offer_code.id => true)
      end

      it "reserves one allocation on a subscription restart awaiting payment" do
        offer_code.update!(amount_percentage: nil, amount_cents: 100, once_per_cart: true, max_purchase_count: 1)
        subscription = create(:subscription, link: membership)
        subscription.purchases << create(:membership_purchase, link: membership, seller: offer_code.user)
        purchase = create(
          :purchase_in_progress,
          link: membership,
          seller: offer_code.user,
          subscription:,
          offer_code:,
          is_original_subscription_purchase: false,
          is_upgrade_purchase: true
        )
        purchase.create_purchase_offer_code_discount!(
          offer_code:,
          offer_code_amount: 100,
          offer_code_is_percent: false,
          once_per_cart: true,
          once_per_cart_allocation_id: SecureRandom.uuid,
          pre_discount_minimum_price_cents: membership.price_cents
        )

        expect(offer_code.quantity_left).to eq(0)
        expect(described_class.uses_left_by_id([offer_code])).to eq(offer_code.id => false)
      end

      it "reserves a use while a cart-level purchase is in progress" do
        offer_code.update!(amount_percentage: nil, amount_cents: 100, once_per_cart: true, max_purchase_count: 1)
        purchase = create(:purchase, link: @product, offer_code:, seller: @product.user,
                                     purchase_state: "in_progress", purchaser: nil)
        purchase.create_purchase_offer_code_discount!(offer_code:, offer_code_amount: 100, offer_code_is_percent: false,
                                                      once_per_cart: true, pre_discount_minimum_price_cents: @product.price_cents)

        expect(offer_code.quantity_left).to eq 0
        expect(described_class.uses_left_by_id([offer_code])).to eq(offer_code.id => false)
        expect(offer_code.is_valid_for_purchase?(excluding_purchase: purchase)).to be(true)

        travel ChargeProcessor::TIME_TO_COMPLETE_SCA + 1.minute

        expect(offer_code.quantity_left).to eq 1
        expect(described_class.uses_left_by_id([offer_code])).to eq(offer_code.id => true)

        purchase.create_processor_payment_intent!(intent_id: "pi_live_offer_code_reservation")

        expect(offer_code.quantity_left).to eq 0
        expect(described_class.uses_left_by_id([offer_code])).to eq(offer_code.id => false)

        purchase.processor_payment_intent.destroy!
        purchase.update!(processor_setup_intent_id: "seti_live_offer_code_reservation")

        expect(offer_code.quantity_left).to eq 0
        expect(described_class.uses_left_by_id([offer_code])).to eq(offer_code.id => false)

        purchase.update!(processor_setup_intent_id: nil)
        purchase.update!(stripe_status: StripeIntentStatus::REQUIRES_ACTION)

        expect(offer_code.quantity_left).to eq 0
        expect(described_class.uses_left_by_id([offer_code])).to eq(offer_code.id => false)

        purchase.update!(purchase_state: "failed")

        expect(offer_code.quantity_left).to eq 1
        expect(described_class.uses_left_by_id([offer_code])).to eq(offer_code.id => true)
      end

      it "does not reserve another use for a preorder charge" do
        offer_code.update!(amount_percentage: nil, amount_cents: 100, once_per_cart: true, max_purchase_count: 2)
        preorder = create(:preorder, preorder_link: create(:preorder_link, link: @product), seller: @product.user)
        authorization = create(
          :preorder_authorization_purchase,
          link: @product,
          offer_code:,
          seller: @product.user,
          preorder:,
          is_preorder_authorization: true
        )
        authorization.create_purchase_offer_code_discount!(
          offer_code:,
          offer_code_amount: 100,
          offer_code_is_percent: false,
          once_per_cart: true,
          pre_discount_minimum_price_cents: @product.price_cents
        )
        charge = create(:purchase, link: @product, offer_code:, seller: @product.user, preorder:,
                                   purchase_state: "in_progress", purchaser: nil)
        charge.create_purchase_offer_code_discount!(offer_code:, offer_code_amount: 100, offer_code_is_percent: false,
                                                    once_per_cart: true, pre_discount_minimum_price_cents: @product.price_cents)

        expect(offer_code.quantity_left).to eq 1
        expect(described_class.uses_left_by_id([offer_code])).to eq(offer_code.id => true)
      end

      it "keeps each purchase's recorded usage mode when the code changes" do
        offer_code.update!(amount_percentage: nil, amount_cents: 100, once_per_cart: false)
        legacy_purchase = create(:purchase, link: @product, offer_code:, seller: @product.user, price_cents: @product.price_cents * 2, quantity: 2)
        legacy_purchase.create_purchase_offer_code_discount!(offer_code:, offer_code_amount: 100, offer_code_is_percent: false,
                                                             once_per_cart: false, pre_discount_minimum_price_cents: @product.price_cents)
        offer_code.update!(once_per_cart: true)
        order_level_purchase = create(:purchase, link: @product, offer_code:, seller: @product.user,
                                                 price_cents: @product.price_cents * 10, quantity: 10)
        order_level_purchase.create_purchase_offer_code_discount!(offer_code:, offer_code_amount: 100, offer_code_is_percent: false,
                                                                  once_per_cart: true, pre_discount_minimum_price_cents: @product.price_cents)

        expect(offer_code.quantity_left).to eq offer_code.max_purchase_count - 3
      end
    end

    describe "product offer codes" do
      let(:offer_code) { create(:percentage_offer_code, products: [@product], amount_percentage: 50, max_purchase_count: 20) }

      it "counts successful purchases" do
        create(:purchase, link: @product, offer_code:, seller: @product.user, price_cents: @product.price_cents)

        expect(offer_code.quantity_left).to eq offer_code.max_purchase_count - 1
      end

      it "sums the quantities of applicable purchases" do
        create(:purchase, link: @product, offer_code:, seller: @product.user, price_cents: @product.price_cents * 20, quantity: 20)

        expect(offer_code.quantity_left).to eq 0
      end
    end
  end

  describe "#inactive?" do
    context "when the offer code has no valid or expiriration date" do
      let(:offer_code) { create(:offer_code) }

      it "returns false" do
        expect(offer_code.inactive?).to eq(false)
      end
    end

    context "when the offer code is valid and has no expiration" do
      let(:offer_code) { create(:offer_code, valid_at: 1.year.ago) }

      it "returns false" do
        expect(offer_code.inactive?).to eq(false)
      end
    end

    context "when the offer code is not yet valid" do
      let(:offer_code) { create(:offer_code, valid_at: 1.year.from_now) }

      it "returns true" do
        expect(offer_code.inactive?).to eq(true)
      end
    end

    context "when the offer code is expired" do
      let(:offer_code) { create(:offer_code, valid_at: 2.years.ago, expires_at: 1.year.ago) }

      it "returns true" do
        expect(offer_code.inactive?).to eq(true)
      end
    end
  end

  describe "#discount" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }

    context "when the discount is fixed" do
      let(:offer_code) { create(:offer_code, products: [product], amount_cents: 100, minimum_quantity: 2, duration_in_billing_cycles: 1, minimum_amount_cents: 100) }

      it "returns the discount" do
        expect(offer_code.discount).to eq(
          {
            type: "fixed",
            cents: 100,
            product_ids: [product.external_id],
            expires_at: nil,
            minimum_quantity: 2,
            duration_in_billing_cycles: 1,
            minimum_amount_cents: 100,
          }
        )
      end

      it "includes a stable allocation identity for order-level pricing" do
        offer_code.update!(once_per_cart: true)

        expect(offer_code.discount).to include(
          once_per_cart: true,
          once_per_cart_id: offer_code.external_id,
          once_per_cart_amount_cents: 100,
          once_per_cart_has_usage_limit: false
        )
      end

      it "identifies a once-per-cart discount with a usage limit" do
        offer_code.update!(once_per_cart: true, max_purchase_count: 1)

        expect(offer_code.discount).to include(once_per_cart_has_usage_limit: true)
      end
    end

    context "when the discount is percentage" do
      let(:offer_code) { create(:percentage_offer_code, amount_percentage: 10, universal: true, valid_at: 1.day.ago, expires_at: 1.day.from_now) }

      it "returns the discount" do
        expect(offer_code.discount).to eq(
          {
            type: "percent",
            percents: 10,
            product_ids: nil,
            expires_at: offer_code.expires_at,
            minimum_quantity: nil,
            duration_in_billing_cycles: nil,
            minimum_amount_cents: nil,
          }
        )
      end
    end

    context "when the discount is universal with excluded products" do
      let(:excluded_product) { create(:product, user: seller) }
      let(:offer_code) { create(:universal_offer_code, user: seller, amount_cents: 100, excluded_products: [excluded_product]) }

      it "returns the discount with the excluded product ids" do
        expect(offer_code.discount).to eq(
          {
            type: "fixed",
            cents: 100,
            product_ids: nil,
            excluded_product_ids: [excluded_product.external_id],
            expires_at: nil,
            minimum_quantity: nil,
            duration_in_billing_cycles: nil,
            minimum_amount_cents: nil,
          }
        )
      end
    end
  end

  describe "#is_amount_valid?" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller, price_cents: 200) }

    context "when the offer code is absolute" do
      context "when the discounted price is 0" do
        let(:offer_code) { create(:offer_code, user: seller, products: [product], amount_cents: 200) }

        it "returns true" do
          expect(offer_code.is_amount_valid?(product)).to eq(true)
        end
      end

      context "when the discounted price is greater than or equal to the minimum" do
        let(:offer_code) { create(:offer_code, user: seller, products: [product], amount_cents: 100) }

        it "returns true" do
          expect(offer_code.is_amount_valid?(product)).to eq(true)
        end
      end

      context "when the discounted price is less than the minimum and not 0" do
        let!(:offer_code) { create(:offer_code, user: seller, products: [product], amount_cents: 100) }

        before do
          product.update!(price_cents: 150)
        end

        it "returns false" do
          expect(offer_code.is_amount_valid?(product)).to eq(false)
        end
      end

      context "when a once-per-cart code requires multiple units" do
        it "validates against the eligible cart price" do
          product.update!(price_cents: 10_00)
          offer_code = build(:offer_code, user: seller, products: [product], amount_cents: 9_50,
                                          once_per_cart: true, minimum_quantity: 2)

          expect(offer_code).to be_valid
          expect(offer_code.is_amount_valid?(product)).to be(true)
        end
      end

      context "when the product is a tiered membership" do
        let(:membership) { create(:membership_product_with_preset_tiered_pricing, user: seller) }
        let!(:offer_code) { create(:offer_code, user: seller, products: [membership], amount_cents: 300) }

        context "when at least one tier has an invalid discounted price" do
          before do
            membership.alive_variants.first.prices.first.update!(price_cents: 350)
          end

          it "returns false" do
            expect(offer_code.is_amount_valid?(membership)).to eq(false)
          end
        end

        context "when all tiers have valid discounted prices" do
          it "returns true" do
            expect(offer_code.is_amount_valid?(membership)).to eq(true)
          end
        end
      end

      context "when the product is a versioned product" do
        let(:versioned_product) { create(:product_with_digital_versions, user: seller) }
        let!(:offer_code) { create(:offer_code, user: seller, products: [versioned_product], amount_cents: 100) }

        context "when at least one version has an invalid discounted price" do
          before do
            versioned_product.alive_variants.first.update!(price_difference_cents: 50)
          end

          it "returns false" do
            expect(offer_code.is_amount_valid?(versioned_product)).to eq(false)
          end
        end

        context "when all versions have valid discounted prices" do
          it "returns true" do
            expect(offer_code.is_amount_valid?(versioned_product)).to eq(true)
          end
        end
      end
    end

    context "when the offer code is percentage" do
      context "when the discounted price is 0" do
        let(:offer_code) { create(:offer_code, user: seller, products: [product], amount_percentage: 100) }

        it "returns true" do
          expect(offer_code.is_amount_valid?(product)).to eq(true)
        end
      end

      context "when the discounted price is greater than or equal to the minimum" do
        let(:offer_code) { create(:offer_code, user: seller, products: [product], amount_percentage: 50) }

        it "returns true" do
          expect(offer_code.is_amount_valid?(product)).to eq(true)
        end
      end

      context "when the discounted price is less than the minimum and not 0" do
        let!(:offer_code) { create(:offer_code, user: seller, products: [product], amount_percentage: 50) }

        before do
          product.update!(price_cents: 150)
        end

        it "returns false" do
          expect(offer_code.is_amount_valid?(product)).to eq(false)
        end
      end
    end

    context "when the offer code is tiered" do
      let!(:offer_code) { create(:tiered_offer_code, user: seller, products: [product]) }

      it "returns true when all tiered discounted prices are valid" do
        expect(offer_code.is_amount_valid?(product)).to eq(true)
      end

      it "returns false when any tiered discounted price is below the minimum" do
        product.update!(price_cents: 150)

        expect(offer_code.is_amount_valid?(product)).to eq(false)
      end
    end
  end

  describe "#applicable?" do
    context "when the offer code is universal and has no currency type" do
      let(:offer_code) { create(:universal_offer_code, user: @product.user, amount_percentage: 10, currency_type: nil) }
      let(:usd_product) { @product }
      let(:eur_product) { create(:product, user: @product.user, price_cents: 1000, price_currency_type: "eur") }

      it "returns true for products regardless of currency" do
        expect(offer_code.applicable?(usd_product)).to eq(true)
        expect(offer_code.applicable?(eur_product)).to eq(true)
      end
    end

    context "when the offer code is universal with a currency type" do
      let(:offer_code) { create(:universal_offer_code, user: @product.user, amount_cents: 100, currency_type: "usd") }
      let(:usd_product) { @product }
      let(:eur_product) { create(:product, user: @product.user, price_cents: 1000, price_currency_type: "eur") }

      it "returns true only for products with matching currency" do
        expect(offer_code.applicable?(usd_product)).to eq(true)
        expect(offer_code.applicable?(eur_product)).to eq(false)
      end
    end

    context "when the offer code is universal with excluded products" do
      let(:excluded_product) { create(:product, user: @product.user, price_cents: 1000, price_currency_type: "usd") }
      let(:offer_code) { create(:universal_offer_code, user: @product.user, amount_percentage: 10, amount_cents: nil, currency_type: nil, excluded_products: [excluded_product]) }

      it "returns false for excluded products and true otherwise" do
        expect(offer_code.applicable?(@product)).to eq(true)
        expect(offer_code.applicable?(excluded_product)).to eq(false)
      end
    end

    context "when the offer code applies to specific products" do
      let(:other_product) { create(:product, user: @product.user, price_cents: 1000, price_currency_type: "usd") }
      let(:offer_code) { create(:offer_code, products: [@product], amount_cents: 100, currency_type: "usd") }

      it "returns true for the associated product and false otherwise" do
        expect(offer_code.applicable?(@product)).to eq(true)
        expect(offer_code.applicable?(other_product)).to eq(false)
      end
    end
  end

  describe "#applicable_products" do
    let(:seller) { create(:user) }
    let!(:product1) { create(:product, user: seller) }
    let!(:product2) { create(:product, user: seller) }

    context "when the offer code is universal" do
      let(:offer_code) { create(:universal_offer_code, user: seller) }

      it "returns the seller's alive products minus the excluded products" do
        expect(offer_code.applicable_products).to match_array([product1, product2])

        offer_code.update!(excluded_products: [product2])
        expect(offer_code.applicable_products).to match_array([product1])
      end
    end

    context "when the offer code applies to specific products" do
      let(:offer_code) { create(:offer_code, user: seller, products: [product1]) }

      it "returns the selected products" do
        expect(offer_code.applicable_products).to match_array([product1])
      end
    end
  end

  describe "excluded product cache invalidation" do
    let(:creator) { create(:user) }
    let!(:product) { create(:product, user: creator) }

    it "invalidates the product's cache when it is excluded and when it is un-excluded" do
      universal_offer_code = create(:universal_offer_code, user: creator)

      expect(product).to receive(:invalidate_cache).twice
      universal_offer_code.update!(excluded_products: [product])
      universal_offer_code.update!(excluded_products: [])
    end
  end

  describe "reindexing products" do
    let(:creator) { create(:user) }
    let(:product1) { create(:product, user: creator) }
    let(:product2) { create(:product, user: creator) }
    let!(:offer_code) { create(:offer_code, user: creator, code: "BLACKFRIDAY2025", products: [product1, product2]) }

    describe "after_save callback" do
      it "waits for the enclosing transaction before indexing a removed product" do
        SendToElasticsearchWorker.clear

        OfferCode.transaction(requires_new: true) do
          OfferCode.transaction(requires_new: true) do
            offer_code.update!(products: [product2])
          end
          expect(SendToElasticsearchWorker.jobs.size).to eq(0)
        end

        expect(SendToElasticsearchWorker).to have_enqueued_sidekiq_job(product1.id, "update", ["offer_codes"])
      end

      it "does not index a removal rolled back with its transaction" do
        SendToElasticsearchWorker.clear

        OfferCode.transaction(requires_new: true) do
          offer_code.update!(products: [product2])
          raise ActiveRecord::Rollback
        end

        expect(SendToElasticsearchWorker.jobs.size).to eq(0)
        expect(offer_code.reload.products).to contain_exactly(product1, product2)
      end

      it "does not index a removal rolled back to a savepoint" do
        SendToElasticsearchWorker.clear

        OfferCode.transaction(requires_new: true) do
          OfferCode.transaction(requires_new: true) do
            offer_code.update!(products: [product2])
            raise ActiveRecord::Rollback
          end
        end

        expect(SendToElasticsearchWorker.jobs.size).to eq(0)
        expect(offer_code.reload.products).to contain_exactly(product1, product2)
      end

      it "indexes a successful retry after a failed removal update" do
        SendToElasticsearchWorker.clear

        expect(offer_code.update(products: [product2], amount_cents: -1)).to be(false)
        expect(SendToElasticsearchWorker.jobs.size).to eq(0)
        expect(offer_code.reload.products).to contain_exactly(product1, product2)

        offer_code.update!(products: [product2])

        expect(SendToElasticsearchWorker).to have_enqueued_sidekiq_job(product1.id, "update", ["offer_codes"])
      end

      it "does not index an old universal scope when its change rolls back" do
        universal_offer_code = create(:universal_offer_code, user: creator)
        SendToElasticsearchWorker.clear

        OfferCode.transaction(requires_new: true) do
          universal_offer_code.update!(universal: false, products: [product2])
          raise ActiveRecord::Rollback
        end

        expect(SendToElasticsearchWorker.jobs.size).to eq(0)
        expect(universal_offer_code.reload).to be_universal
      end

      it "reindexes formerly eligible products when a universal code becomes product-specific" do
        universal_offer_code = create(:universal_offer_code, user: creator)
        SendToElasticsearchWorker.clear

        universal_offer_code.update!(universal: false, products: [product2])

        expect(product1.reload.product_and_universal_offer_codes).not_to include(universal_offer_code)
        expect(SendToElasticsearchWorker).to have_enqueued_sidekiq_job(product1.id, "update", ["offer_codes"])
      end

      it "reindexes the old currency's products when a universal discount changes currency" do
        universal_offer_code = create(:universal_offer_code, user: creator, currency_type: "usd")
        create(:product, user: creator, price_currency_type: "eur")
        SendToElasticsearchWorker.clear

        universal_offer_code.update!(currency_type: "eur")

        expect(product1.reload.product_and_universal_offer_codes).not_to include(universal_offer_code)
        expect(SendToElasticsearchWorker).to have_enqueued_sidekiq_job(product1.id, "update", ["offer_codes"])
      end

      it "enqueues the previous universal catalog in bounded batches" do
        universal_offer_code = create(:universal_offer_code, user: creator)
        SendToElasticsearchWorker.clear
        stub_const("OfferCode::PRODUCT_REINDEX_BATCH_SIZE", 1)

        batch_sizes = []
        allow(SendToElasticsearchWorker).to receive(:perform_bulk) do |args, **|
          batch_sizes << args.size
        end

        universal_offer_code.update!(universal: false, products: [product2])

        expect(batch_sizes.max).to eq(1)
        expect(batch_sizes.sum).to be >= 2
      end

      it "reindexes products removed from a product-specific offer code" do
        SendToElasticsearchWorker.clear

        offer_code.update!(products: [product2])

        expect(product1.reload.product_and_universal_offer_codes).not_to include(offer_code)
        expect(SendToElasticsearchWorker).to have_enqueued_sidekiq_job(product1.id, "update", ["offer_codes"])
        expect(SendToElasticsearchWorker).to have_enqueued_sidekiq_job(product2.id, "update", ["offer_codes"])
      end

      it "reindexes products when they are excluded from a universal offer code" do
        universal_offer_code = create(:universal_offer_code, user: creator)

        expect(SendToElasticsearchWorker).to have_enqueued_sidekiq_job(product1.id, "update", ["offer_codes"])
        expect(SendToElasticsearchWorker).to have_enqueued_sidekiq_job(product2.id, "update", ["offer_codes"])
        universal_offer_code.update!(excluded_products: [product1])
      end

      it "reindexes associated products when offer code is updated" do
        expect(SendToElasticsearchWorker).to have_enqueued_sidekiq_job(product1.id, "update", ["offer_codes"])
        expect(SendToElasticsearchWorker).to have_enqueued_sidekiq_job(product2.id, "update", ["offer_codes"])

        offer_code.update(amount_cents: 500)
      end

      it "reindexes associated products when offer code code is changed" do
        expect(SendToElasticsearchWorker).to have_enqueued_sidekiq_job(product1.id, "update", ["offer_codes"])
        expect(SendToElasticsearchWorker).to have_enqueued_sidekiq_job(product2.id, "update", ["offer_codes"])

        offer_code.update(code: "NEWYEAR2025")
      end
    end

    describe "after_destroy callback" do
      let(:products_to_reindex) { [product1, product2] }

      before do
        allow(Link).to receive(:where).with(id: products_to_reindex.map(&:id)).and_return(products_to_reindex)
      end

      it "reindexes associated products when offer code is destroyed" do
        expect(SendToElasticsearchWorker).to have_enqueued_sidekiq_job(product1.id, "update", ["offer_codes"])
        expect(SendToElasticsearchWorker).to have_enqueued_sidekiq_job(product2.id, "update", ["offer_codes"])

        offer_code.destroy
      end
    end

    describe "#reindex_associated_products" do
      it "handles offer codes with no products" do
        offer_code_without_products = create(:offer_code, user: creator, code: "EMPTY")

        expect { offer_code_without_products.update(amount_cents: 1000) }.not_to raise_error
      end

      it "only reindexes products that exist" do
        expect(SendToElasticsearchWorker).to have_enqueued_sidekiq_job(product1.id, "update", ["offer_codes"])
        expect(SendToElasticsearchWorker).to have_enqueued_sidekiq_job(product2.id, "update", ["offer_codes"])

        offer_code.send(:reindex_associated_products)
      end
    end
  end

  describe "search_by_name" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }

    before do
      @offer_code1 = create(:offer_code, user: seller, products: [product], name: "Black Friday Sale", code: "BF2025")
      @offer_code2 = create(:offer_code, user: seller, products: [product], name: "Summer Discount", code: "SUMMER25")
      @offer_code3 = create(:offer_code, user: seller, products: [product], name: "Holiday Special", code: "HOLIDAY")
      @universal_code1 = create(:universal_offer_code, user: seller, name: "Universal Black Friday", code: "UNI_BF", currency_type: "usd")
      @universal_code2 = create(:universal_offer_code, user: seller, name: "Universal Summer", code: "UNI_SUMMER", currency_type: "usd")
    end

    it "filters by name and returns matching offer codes" do
      codes = OfferCode.search_by_name("Black Friday")

      expect(codes).to include(@offer_code1, @universal_code1)
      expect(codes).not_to include(@offer_code2, @offer_code3, @universal_code2)
      expect(codes.size).to eq(2)
    end

    it "does not match by code, only by name" do
      codes = OfferCode.search_by_name("BF2025")

      # Should not find any codes even though "BF2025" matches the code
      # because search is now by name only
      expect(codes).to be_empty
    end

    it "matches case-insensitively" do
      codes = OfferCode.search_by_name("black friday")

      expect(codes).to include(@offer_code1, @universal_code1)
      expect(codes.size).to eq(2)
    end

    it "matches partial names" do
      codes = OfferCode.search_by_name("Summer")

      expect(codes).to include(@offer_code2, @universal_code2)
      expect(codes.size).to eq(2)
    end

    it "returns empty relation when no codes match the query" do
      codes = OfferCode.search_by_name("No Match")

      expect(codes).to be_empty
    end

    it "handles nil query" do
      codes = OfferCode.search_by_name(nil)

      expect(codes).to be_empty
    end

    it "handles empty string query" do
      codes = OfferCode.search_by_name("")

      expect(codes).to be_empty
    end

    it "strips whitespace from query" do
      codes = OfferCode.search_by_name("  Black Friday  ")

      expect(codes).to include(@offer_code1, @universal_code1)
      expect(codes.size).to eq(2)
    end
  end

  describe "#auto_delete_if_single_use_exhausted!" do
    it "soft-deletes a single-use code that has been fully used" do
      offer_code = create(:offer_code, products: [@product], max_purchase_count: 1)
      # Stub the after_commit hook so the purchase doesn't auto-delete the code
      allow_any_instance_of(Purchase).to receive(:auto_delete_single_use_offer_code)
      create(:purchase, offer_code:, link: @product, seller: @product.user, price_cents: @product.price_cents)

      expect { offer_code.auto_delete_if_single_use_exhausted! }.to change { offer_code.reload.deleted? }.from(false).to(true)
    end

    it "does not delete a single-use code that still has quantity left" do
      offer_code = create(:offer_code, products: [@product], max_purchase_count: 1)

      expect { offer_code.auto_delete_if_single_use_exhausted! }.not_to change { offer_code.reload.deleted? }
    end

    it "does not delete a multi-use code even when fully used" do
      offer_code = create(:offer_code, products: [@product], max_purchase_count: 5)
      5.times { create(:purchase, offer_code:, link: @product, seller: @product.user, price_cents: @product.price_cents) }

      expect { offer_code.auto_delete_if_single_use_exhausted! }.not_to change { offer_code.reload.deleted? }
    end

    it "does not delete an unlimited-use code" do
      offer_code = create(:offer_code, products: [@product], max_purchase_count: nil)

      expect { offer_code.auto_delete_if_single_use_exhausted! }.not_to change { offer_code.reload.deleted? }
    end

    it "does not delete a code that is already deleted" do
      offer_code = create(:offer_code, products: [@product], max_purchase_count: 1)
      allow_any_instance_of(Purchase).to receive(:auto_delete_single_use_offer_code)
      create(:purchase, offer_code:, link: @product, seller: @product.user, price_cents: @product.price_cents)
      offer_code.mark_deleted!

      expect { offer_code.auto_delete_if_single_use_exhausted! }.not_to change { offer_code.reload.deleted_at }
    end
  end

  describe "existing customer discount validations" do
    it "requires at least one ownership product when existing_customers_only is on" do
      offer_code = OfferCode.new(
        code: "renew",
        user: @product.user,
        products: [@product],
        amount_percentage: 50,
        existing_customers_only: true,
      )

      expect(offer_code).not_to be_valid
      expect(offer_code.errors.full_messages).to include("Pick at least one product the customer must already own.")
    end

    it "is valid when existing_customers_only is on and ownership products are set" do
      offer_code = OfferCode.new(
        code: "renew",
        user: @product.user,
        products: [@product],
        ownership_products: [@product],
        amount_percentage: 50,
        existing_customers_only: true,
      )

      expect(offer_code).to be_valid
    end

    it "accepts ownership tiers without existing_customers_only" do
      offer_code = build(:tiered_offer_code, products: [@product], existing_customers_only: false, ownership_products: [])

      expect(offer_code).to be_valid
    end

    it "rejects ownership tiers combined with duration_in_billing_cycles" do
      offer_code = build(:tiered_offer_code, products: [@product], duration_in_billing_cycles: 1)

      expect(offer_code).not_to be_valid
      expect(offer_code.errors.full_messages).to include("Remove the membership duration to use tiered discounts.")
    end

    it "rejects ownership tiers combined with a fixed-amount discount" do
      offer_code = build(:tiered_offer_code, products: [@product], amount_cents: 500, amount_percentage: nil, currency_type: "usd")

      expect(offer_code).not_to be_valid
      expect(offer_code.errors.full_messages).to include("Switch the discount type to percentage to use tiers.")
    end

    it "rejects tiers that don't start at zero months" do
      offer_code = build(:tiered_offer_code, products: [@product], ownership_duration_tiers: [{ "months" => 3, "amount_percentage" => 50 }])

      expect(offer_code).not_to be_valid
      expect(offer_code.errors.full_messages).to include("The first tier must start at 0 months.")
    end

    it "rejects duplicate tier months" do
      offer_code = build(:tiered_offer_code, products: [@product], ownership_duration_tiers: [
                           { "months" => 0, "amount_percentage" => 10 },
                           { "months" => 0, "amount_percentage" => 50 },
                         ])

      expect(offer_code).not_to be_valid
      expect(offer_code.errors.full_messages).to include("Each tier needs a different starting month.")
    end

    it "rejects tiers with out-of-range percentages" do
      offer_code = build(:tiered_offer_code, products: [@product], ownership_duration_tiers: [{ "months" => 0, "amount_percentage" => 150 }])

      expect(offer_code).not_to be_valid
      expect(offer_code.errors.full_messages).to include("Each tier percentage must be between 0 and 100.")
    end

    it "rejects tiers that discount a product below the minimum price" do
      offer_code = build(:tiered_offer_code,
                         products: [@product],
                         ownership_duration_tiers: [
                           { "months" => 0, "amount_percentage" => 0 },
                           { "months" => 12, "amount_percentage" => 99 },
                         ])

      expect(offer_code).not_to be_valid
      expect(offer_code.errors.full_messages).to include("The price after discount for all of your products must be either $0 or at least $0.99.")
    end
  end

  describe "#evaluate_for_buyer" do
    let(:seller) { @product.user }
    let(:buyer) { create(:user) }

    it "returns the standard discount when the code is not existing-customers-only" do
      offer_code = create(:offer_code, products: [@product], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)
      expect(offer_code.evaluate_for_buyer(buyer)).to eq(offer_code.discount)
    end

    it "returns nil when the buyer is nil and the code is existing-customers-only" do
      offer_code = create(:offer_code, :for_existing_customers, products: [@product], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)
      expect(offer_code.evaluate_for_buyer(nil)).to be_nil
    end

    it "returns nil for unauthenticated display when the code is existing-customers-only" do
      offer_code = create(:offer_code, :for_existing_customers, products: [@product], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)
      expect(offer_code.discount_for_display).to be_nil
    end

    it "returns configured discounts for seller display when the code is existing-customers-only" do
      offer_code = create(:offer_code, :for_existing_customers, products: [@product], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)

      expect(offer_code.configured_discount_for_display).to include(type: "percent", percents: 30)
    end

    it "returns nil when the buyer has not purchased any ownership product" do
      offer_code = create(:offer_code, :for_existing_customers, products: [@product], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)
      expect(offer_code.evaluate_for_buyer(buyer)).to be_nil
    end

    it "returns the standard discount when the buyer owns an ownership product" do
      offer_code = create(:offer_code, :for_existing_customers, products: [@product], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)
      create(:purchase, purchaser: buyer, link: @product, price_cents: @product.price_cents)
      expect(offer_code.evaluate_for_buyer(buyer)).to include(type: "percent", percents: 30)
    end

    it "returns the standard discount when the buyer's only qualifying purchase was made as a guest under the same email" do
      offer_code = create(:offer_code, :for_existing_customers, products: [@product], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)
      create(:purchase, purchaser: nil, email: buyer.email, link: @product, seller:, price_cents: @product.price_cents)

      expect(offer_code.evaluate_for_buyer(buyer)).to include(type: "percent", percents: 30)
    end

    it "ignores a guest purchase made under a different email" do
      offer_code = create(:offer_code, :for_existing_customers, products: [@product], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)
      create(:purchase, purchaser: nil, email: "someone-else@example.com", link: @product, seller:, price_cents: @product.price_cents)

      expect(offer_code.evaluate_for_buyer(buyer)).to be_nil
    end

    it "ignores a guest purchase of a product the code does not require" do
      other_product = create(:product, user: seller, price_cents: 500)
      offer_code = create(:offer_code, :for_existing_customers, products: [@product], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)
      create(:purchase, purchaser: nil, email: buyer.email, link: other_product, seller:, price_cents: other_product.price_cents)

      expect(offer_code.evaluate_for_buyer(buyer)).to be_nil
    end

    it "ignores a guest purchase matching an unconfirmed account email" do
      unconfirmed_buyer = create(:unconfirmed_user)
      offer_code = create(:offer_code, :for_existing_customers, products: [@product], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)
      create(:purchase, purchaser: nil, email: unconfirmed_buyer.email, link: @product, seller:, price_cents: @product.price_cents)

      expect(offer_code.evaluate_for_buyer(unconfirmed_buyer)).to be_nil
    end

    it "still honors an account-linked purchase for a buyer whose email is unconfirmed" do
      unconfirmed_buyer = create(:unconfirmed_user)
      offer_code = create(:offer_code, :for_existing_customers, products: [@product], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)
      create(:purchase, purchaser: unconfirmed_buyer, link: @product, seller:, price_cents: @product.price_cents)

      expect(offer_code.evaluate_for_buyer(unconfirmed_buyer)).to include(type: "percent", percents: 30)
    end

    it "treats a refunded guest purchase as not qualifying" do
      offer_code = create(:offer_code, :for_existing_customers, products: [@product], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)
      create(:purchase, purchaser: nil, email: buyer.email, link: @product, seller:, price_cents: @product.price_cents, stripe_refunded: true)

      expect(offer_code.evaluate_for_buyer(buyer)).to be_nil
    end

    it "treats refunded purchases as not qualifying" do
      offer_code = create(:offer_code, :for_existing_customers, products: [@product], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)
      create(:purchase, purchaser: buyer, link: @product, seller:, price_cents: @product.price_cents, stripe_refunded: true)
      expect(offer_code.evaluate_for_buyer(buyer)).to be_nil
    end

    it "treats refunded membership purchases as not qualifying" do
      membership = create(:subscription_product, user: seller, price_cents: 10_00)
      offer_code = create(:offer_code, :for_existing_customers, products: [membership], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)
      subscription = create(:subscription, link: membership, user: buyer)
      create(:membership_purchase, purchaser: buyer, link: membership, seller:, subscription:, price_cents: membership.price_cents, stripe_refunded: true)

      expect(offer_code.evaluate_for_buyer(buyer)).to be_nil
    end

    it "treats chargedback purchases (not reversed) as not qualifying" do
      offer_code = create(:offer_code, :for_existing_customers, products: [@product], amount_cents: nil, amount_percentage: 30, currency_type: nil, user: seller)
      create(:purchase, purchaser: buyer, link: @product, seller:, price_cents: @product.price_cents, chargeback_date: 1.day.ago)
      expect(offer_code.evaluate_for_buyer(buyer)).to be_nil
    end

    context "with tiered discounts" do
      let(:offer_code) do
        create(:offer_code,
               user: seller,
               products: [@product],
               ownership_products: [@product],
               existing_customers_only: true,
               amount_cents: nil,
               amount_percentage: 0,
               currency_type: nil,
               ownership_duration_tiers: [
                 { "months" => 0, "amount_percentage" => 10 },
                 { "months" => 6, "amount_percentage" => 30 },
                 { "months" => 12, "amount_percentage" => 50 },
               ])
      end

      it "returns the lowest tier when the buyer has 0 months of ownership" do
        create(:purchase, purchaser: buyer, link: @product, price_cents: @product.price_cents)
        expect(offer_code.evaluate_for_buyer(buyer)).to include(type: "percent", percents: 10)
      end

      it "returns the matching tier based on ownership duration" do
        create(:purchase, purchaser: buyer, link: @product, seller:, price_cents: @product.price_cents, created_at: 7.months.ago)
        expect(offer_code.evaluate_for_buyer(buyer)).to include(type: "percent", percents: 30)
      end

      it "returns the highest tier when ownership exceeds the last threshold" do
        create(:purchase, purchaser: buyer, link: @product, seller:, price_cents: @product.price_cents, created_at: 24.months.ago)
        expect(offer_code.evaluate_for_buyer(buyer)).to include(type: "percent", percents: 50)
      end

      it "returns nil for unauthenticated display" do
        expect(offer_code.discount_for_display).to be_nil
      end

      it "returns the configured tier range for seller display" do
        expect(offer_code.configured_discount_for_display).to include(
          type: "percent",
          percents: 50,
          tiered: true,
          min_percents: 10,
          max_percents: 50
        )
      end

      it "ignores purchases that do not grant library ownership" do
        create(:purchase, purchaser: buyer, link: @product, seller:, price_cents: @product.price_cents, is_gift_sender_purchase: true)
        create(:purchase, purchaser: buyer, link: @product, seller:, price_cents: @product.price_cents, is_access_revoked: true)
        create(:purchase, purchaser: buyer, link: @product, seller:, price_cents: @product.price_cents, is_additional_contribution: true)

        expect(offer_code.evaluate_for_buyer(buyer)).to be_nil
      end

      it "counts calendar months across yearly anniversaries" do
        travel_to(Time.zone.local(2026, 5, 14, 12)) do
          create(:purchase, purchaser: buyer, link: @product, seller:, price_cents: @product.price_cents, created_at: 1.year.ago)
          expect(offer_code.evaluate_for_buyer(buyer)).to include(type: "percent", percents: 50)
        end
      end

      it "uses a guest purchase under the buyer's email to determine ownership duration" do
        create(:purchase, purchaser: nil, email: buyer.email, link: @product, seller:, price_cents: @product.price_cents, created_at: 24.months.ago)
        expect(offer_code.evaluate_for_buyer(buyer)).to include(type: "percent", percents: 50)
      end

      it "uses the OLDEST qualifying purchase to determine ownership duration" do
        create(:purchase, purchaser: buyer, link: @product, seller:, price_cents: @product.price_cents, created_at: 24.months.ago)
        create(:purchase, purchaser: buyer, link: @product, seller:, price_cents: @product.price_cents, created_at: 2.months.ago)
        expect(offer_code.evaluate_for_buyer(buyer)).to include(type: "percent", percents: 50)
      end
    end

    context "with tiered discounts and no existing_customers_only flag" do
      let(:offer_code) do
        create(:offer_code,
               user: seller,
               products: [@product],
               amount_cents: nil,
               amount_percentage: 0,
               currency_type: nil,
               ownership_duration_tiers: [
                 { "months" => 0, "amount_percentage" => 0 },
                 { "months" => 12, "amount_percentage" => 50 },
               ])
      end

      it "returns the 0-month tier when the buyer is nil" do
        expect(offer_code.evaluate_for_buyer(nil)).to include(type: "percent", percents: 0)
      end

      it "returns the 0-month tier when the buyer has no prior purchase" do
        expect(offer_code.evaluate_for_buyer(buyer)).to include(type: "percent", percents: 0)
      end

      it "returns the matching tier based on a prior purchase of an applicable product" do
        create(:purchase, purchaser: buyer, link: @product, seller:, price_cents: @product.price_cents, created_at: 14.months.ago)
        expect(offer_code.evaluate_for_buyer(buyer)).to include(type: "percent", percents: 50)
      end

      it "returns the configured tier range for anonymous display" do
        expect(offer_code.discount_for_display).to include(
          type: "percent",
          tiered: true,
          min_percents: 0,
          max_percents: 50,
        )
      end

      it "scopes tenure to the product passed via product: when the code applies to several products" do
        other_product = create(:product, user: seller, price_cents: 10_00)
        multi_code = create(:offer_code,
                            user: seller,
                            products: [@product, other_product],
                            amount_cents: nil,
                            amount_percentage: 0,
                            currency_type: nil,
                            ownership_duration_tiers: [
                              { "months" => 0, "amount_percentage" => 0 },
                              { "months" => 12, "amount_percentage" => 50 },
                            ])
        create(:purchase, purchaser: buyer, link: other_product, seller:, price_cents: other_product.price_cents, created_at: 14.months.ago)

        expect(multi_code.evaluate_for_buyer(buyer, product: @product)).to include(type: "percent", percents: 0)
        expect(multi_code.evaluate_for_buyer(buyer, product: other_product)).to include(type: "percent", percents: 50)
      end
    end
  end

  describe ".renewal_eligible" do
    it "excludes codes with an empty ownership_duration_tiers array" do
      seller = @product.user
      blank_tiered = create(:offer_code, user: seller, products: [@product], amount_cents: nil, amount_percentage: 10, currency_type: nil)
      blank_tiered.update_column(:ownership_duration_tiers, [])

      expect(OfferCode.renewal_eligible).not_to include(blank_tiered)
    end

    it "includes codes with a populated ownership_duration_tiers array" do
      seller = @product.user
      tiered = create(:tiered_offer_code, user: seller, products: [@product])

      expect(OfferCode.renewal_eligible).to include(tiered)
    end

    it "includes existing-customer-only codes regardless of tiers" do
      seller = @product.user
      existing_only = create(:offer_code, :for_existing_customers, user: seller, products: [@product], amount_cents: nil, amount_percentage: 20, currency_type: nil)

      expect(OfferCode.renewal_eligible).to include(existing_only)
    end
  end
end
