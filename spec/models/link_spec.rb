# frozen_string_literal: true

require "spec_helper"
require "shared_examples/max_purchase_count_concern"

describe Link, :vcr do
  include PreorderHelper

  let(:link) { create(:product) }
  subject { link }

  before do
    @mock_obj = Object.new
    allow(@mock_obj).to receive(:code).and_return(200)
    allow(HTTParty).to receive(:head).and_return(@mock_obj)
  end

  it_behaves_like "MaxPurchaseCount concern", :product

  it "is not a single-unit currency" do
    expect(subject.send(:single_unit_currency?)).to be(false)
  end

  describe "max_purchase_count validations" do
    it "can be set on new records with no purchases" do
      expect(build(:product, max_purchase_count: nil).valid?).to eq(true)
    end

    it "prevents to change when inventory sold is greater than the new value" do
      product = create(:product, max_purchase_count: 5)
      create_list(:purchase, 2, link: product)
      product.reload
      expect(product.valid?).to eq(true)
      product.max_purchase_count = 1
      expect(product.valid?).to eq(false)
    end

    it "does not make the record invalid when inventory sold is greater" do
      # While this situation should never happen, it's still possible.
      # Ensuring the record stays valid allows the creator to still change other columns.
      product = create(:product)
      create_list(:purchase, 2, link: product)
      product.update_column(:max_purchase_count, 1)
      expect(product.reload.valid?).to eq(true)
    end

    it "allows it to be set on new records with no purchases" do
      expect(build(:product, max_purchase_count: 100).valid?).to eq(true)
    end
  end

  it "allows > $1000 links for verified users" do
    expect(build(:product, user: create(:user, verified: true), price_cents: 100_100).valid?).to be(true)
  end

  describe "price_must_be_within_range validation" do
    it "succeeds if prices are within acceptable bounds" do
      link = build(:product, price_cents: 1_00)
      link2 = build(:product, price_cents: 5000_00)

      expect(link).to be_valid
      expect(link2).to be_valid
    end

    it "fails if price is too high" do
      link = build(:product, price_cents: 5000_01)

      expect(link).not_to be_valid
      expect(link.errors.full_messages).to include "Sorry, we don't support pricing products above $5,000."
    end

    it "fails if price is too low" do
      link = build(:product, price_cents: 98)

      expect(link).not_to be_valid
      expect(link.errors.full_messages).to include "Sorry, a product must be at least $0.99."
    end

    context "when product has prices in multiple currencies" do
      let(:product) { create(:product, price_currency_type: "usd", price_cents: 100) }

      it "validates prices for the current currency against correct thresholds when switching currencies" do
        usd_price = product.default_price
        expect(usd_price.currency).to eq "usd"
        expect(usd_price.price_cents).to eq 100

        expect do
          product.update!(price_currency_type: "inr", price_cents: 5000)
        end
          .to raise_error(ActiveRecord::RecordInvalid)
          .with_message("Validation failed: Sorry, a product must be at least ₹73.")

        # The USD 1.00 is lower than the INR 73.00 dollar threshold, but should
        # be ignored since it's not the current currency
        expect do
          product.update!(price_currency_type: "inr", price_cents: 50000)
        end
          .to_not raise_error(ActiveRecord::RecordInvalid)
      end
    end
  end

  describe "native_type inclusion validation" do
    it "fails if native_type is nil" do
      link = build(:product, native_type: nil)

      expect(link).to be_invalid

      expect { link.save!(validate: false) }.to raise_error ActiveRecord::NotNullViolation
    end

    it "succeeds if native_type is in the allowed list" do
      link = build(:product, native_type: "digital")

      expect(link).to be_valid
    end

    it "fails if native_type is not in the allowed list" do
      link = build(:product, native_type: "invalid")

      expect(link).not_to be_valid
      expect(link.errors.full_messages).to include("Product type is not included in the list")
    end
  end

  describe "discover_fee_per_thousand inclusion validation" do
    let(:product) { build(:product) }

    it "succeeds if discover_fee_per_thousand is in the allowed list" do
      product.discover_fee_per_thousand = 100
      expect(product).to be_valid

      product.discover_fee_per_thousand = 300
      expect(product).to be_valid

      product.discover_fee_per_thousand = 1000
      expect(product).to be_valid

      product.discover_fee_per_thousand = 400
      expect(product).to be_valid

      product.discover_fee_per_thousand = 100
      expect(product).to be_valid
    end

    it "fails if discover_fee_per_thousand is not in the allowed list" do
      message = "Gumroad fee must be between 30% and 100%"

      product.discover_fee_per_thousand = 0
      expect(product).not_to be_valid
      expect(product.errors.full_messages).to include(message)

      product.discover_fee_per_thousand = nil
      expect(product).not_to be_valid
      expect(product.errors.full_messages).to include(message)

      product.discover_fee_per_thousand = -1
      expect(product).not_to be_valid
      expect(product.errors.full_messages).to include(message)

      product.discover_fee_per_thousand = 10
      expect(product).not_to be_valid
      expect(product.errors.full_messages).to include(message)

      product.discover_fee_per_thousand = 1001
      expect(product).not_to be_valid
      expect(product.errors.full_messages).to include(message)
    end
  end

  describe "alive_category_variants_presence validation" do
    describe "for physical products" do
      let(:product) { create(:physical_product) }

      it "succeeds when the product has no versions" do
        expect { product.save! }.to_not raise_error

        expect(product).to be_valid
        expect(product.errors.any?).to be(false)
      end

      it "succeeds when the product has non-empty versions" do
        category_one = create(:variant_category, link: product)
        category_two = create(:variant_category, link: product)
        create(:sku, link: product)
        create(:variant, variant_category: category_one)
        create(:variant, variant_category: category_two)

        expect { product.save! }.to_not raise_error

        expect(product).to be_valid
        expect(product.errors.any?).to be(false)
      end

      it "fails when the product has empty versions" do
        category_one = create(:variant_category, link: product)
        create(:variant_category, link: product)
        create(:sku, link: product)
        create(:variant, variant_category: category_one)

        expect { product.save! }.to raise_error(ActiveRecord::RecordInvalid)

        expect(product).to_not be_valid
        expect(product.errors.full_messages.to_sentence).to eq("Sorry, the product versions must have at least one option.")
      end
    end

    describe "for non-physical products" do
      let(:product) { create(:product) }

      it "succeeds when the product has no versions" do
        expect { product.save! }.to_not raise_error

        expect(product).to be_valid
        expect(product.errors.any?).to be(false)
      end

      it "succeeds when the product has non-empty versions" do
        category_one = create(:variant_category, link: product)
        category_two = create(:variant_category, link: product)
        create(:variant, variant_category: category_one)
        create(:variant, variant_category: category_two)

        expect { product.save! }.to_not raise_error

        expect(product).to be_valid
        expect(product.errors.any?).to be(false)
      end

      it "fails when the product has empty versions" do
        create(:variant_category, link: product)
        category_two = create(:variant_category, link: product)
        create(:variant, variant_category: category_two)

        expect { product.save! }.to raise_error(ActiveRecord::RecordInvalid)

        expect(product).to_not be_valid
        expect(product.errors.full_messages.to_sentence).to eq("Sorry, the product versions must have at least one option.")
      end
    end
  end

  describe "free trial validation" do
    context "when product is recurring billing" do
      it "allows free_trial_enabled to be set" do
        product = build(:subscription_product, free_trial_enabled: true, free_trial_duration_unit: :week, free_trial_duration_amount: 1)
        expect(product).to be_valid
      end

      it "validates presence of free trial properties if free trial is enabled" do
        product = build(:subscription_product, free_trial_enabled: true)
        expect(product).not_to be_valid
        expect(product.errors.full_messages).to match_array ["Free trial duration unit can't be blank", "Free trial duration amount can't be blank"]

        product.free_trial_duration_unit = :week
        product.free_trial_duration_amount = 1
        expect(product).to be_valid
      end

      it "skips validating free_trial_duration_amount unless changed" do
        product = create(:subscription_product, free_trial_enabled: true, free_trial_duration_unit: :week, free_trial_duration_amount: 1)
        product.update_attribute(:free_trial_duration_amount, 2) # skip validations
        expect(product).to be_valid

        product.free_trial_duration_amount = 3
        expect(product).not_to be_valid
      end

      it "does not validate presence of free trial properties if free trial is disabled" do
        product = build(:subscription_product, free_trial_enabled: false)
        expect(product).to be_valid
      end

      it "only allows permitted free trial durations" do
        product = build(:subscription_product, free_trial_enabled: true, free_trial_duration_unit: :week, free_trial_duration_amount: 1)
        expect(product).to be_valid

        product.free_trial_duration_amount = 2
        expect(product).not_to be_valid

        product.free_trial_duration_amount = 0.5
        expect(product).not_to be_valid
      end
    end

    context "when product is not recurring billing" do
      it "does not allow free_trial_enabled to be set" do
        product = build(:product, free_trial_enabled: true)
        expect(product).not_to be_valid
        expect(product.errors.full_messages).to include "Free trials are only allowed for subscription products."
      end

      it "does not allow free trial properties to be set" do
        product = build(:product, free_trial_duration_unit: :week, free_trial_duration_amount: 1)
        expect(product).not_to be_valid
        expect(product.errors.full_messages).to include "Free trials are only allowed for subscription products."
      end
    end
  end

  describe "callbacks" do
    describe "set_default_discover_fee_per_thousand" do
      it "sets the boosted discover fee when user has discover_boost_enabled" do
        user = create(:user, discover_boost_enabled: true)
        product = build(:product, user: user)
        product.save
        expect(product.discover_fee_per_thousand).to eq Link::DEFAULT_BOOSTED_DISCOVER_FEE_PER_THOUSAND
      end

      it "doesn't set the boosted discover fee when user doesn't have discover_boost_enabled" do
        user = create(:user)
        user.update!(discover_boost_enabled: false)
        product = build(:product, user: user)
        product.save
        expect(product.discover_fee_per_thousand).to eq 100
      end
    end

    describe "initialize_tier_if_needed" do
      it "creates a Tier variant category and default tier" do
        product = create(:membership_product)

        expect(product.tier_category.title).to eq "Tier"
        expect(product.tiers.first.name).to eq "Untitled"
      end

      it "creates a default price for the default tier" do
        product = create(:membership_product, price_cents: 600)

        prices = product.default_tier.prices

        expect(prices.count).to eq 1
        expect(prices.first.price_cents).to eq 600
        expect(prices.first.recurrence).to eq "monthly"
      end

      it "creates a price with price_cents 0 for the product" do
        product = create(:membership_product, price_cents: 600)

        prices = product.prices

        expect(prices.count).to eq 1
        expect(prices.first.price_cents).to eq 0
        expect(prices.first.recurrence).to eq "monthly"
      end

      it "sets subscription_duration to the default if not set" do
        product = build(:membership_product, subscription_duration: nil)
        product.save(validate: false) # skip default price validation, which fails

        expect(product.subscription_duration).to eq BasePrice::Recurrence::DEFAULT_TIERED_MEMBERSHIP_RECURRENCE
      end

      describe "single-unit currencies" do
        it "sets prices correctly" do
          product = create(:membership_product, price_currency_type: "jpy", price_cents: 5000)

          tier_price = product.default_tier.prices.first
          expect(tier_price.currency).to eq "jpy"
          expect(tier_price.price_cents).to eq 5000
        end
      end
    end

    describe "reset_moderated_by_iffy_flag" do
      let(:product) { create(:product, moderated_by_iffy: true) }

      context "when the product is alive" do
        it "resets the moderated_by_iffy flag when description changes" do
          expect do
            product.update!(description: "New description")
          end.to change { product.reload.moderated_by_iffy }.from(true).to(false)
        end

        it "does not reset the moderated_by_iffy flag when other attributes change" do
          expect do
            product.update!(price_cents: 1000)
          end.not_to change { product.reload.moderated_by_iffy }
        end
      end
    end

    describe "queue_iffy_ingest_job_if_unpublished_by_admin" do
      let(:product) { create(:product) }

      it "enqueues an Iffy::Product::IngestJob when the product has changed and was already unpublished by admin" do
        product.update!(is_unpublished_by_admin: true)
        product.update!(description: "New description")
        expect(Iffy::Product::IngestJob).to have_enqueued_sidekiq_job(product.id)
      end

      it "does not enqueue an Iffy::Product::IngestJob when the product is only unpublished by admin" do
        expect do
          product.unpublish!(is_unpublished_by_admin: true)
        end.not_to change { Iffy::Product::IngestJob.jobs.size }
      end

      it "does not enqueue an Iffy::Product::IngestJob when the product is not unpublished by admin" do
        expect do
          product.update!(description: "New description")
        end.not_to change { Iffy::Product::IngestJob.jobs.size }
      end
    end

    describe "initialize_suggested_amount_if_needed!" do
      let(:seller) { create(:user, :eligible_for_service_products) }
      let(:product) { build(:product, user: seller, price_cents: 200) }

      context "native type is not a coffee" do
        it "does nothing" do
          product.save
          expect(product.price_cents).to eq(200)
          expect(product.variant_categories_alive).to be_empty
          expect(product.alive_variants).to be_empty
          expect(product.customizable_price).to be_nil
        end
      end

      context "native type is a coffee" do
        before { product.native_type = Link::NATIVE_TYPE_COFFEE }

        it "creates a suggested amount variant category and variant and resets the base price" do
          product.save!
          product.reload
          expect(product.price_cents).to eq(0)
          expect(product.variant_categories_alive.first.title).to eq("Suggested Amounts")
          expect(product.alive_variants.first.name).to eq("")
          expect(product.alive_variants.first.price_difference_cents).to eq(200)
          expect(product.customizable_price).to eq(true)
        end
      end
    end

    describe "initialize_call_limitation_info_if_needed!" do
      let(:seller) { create(:user, :eligible_for_service_products) }
      let(:product) { build(:product, user: seller, price_cents: 200) }

      context "native type is not call" do
        it "does not create a call limitations record" do
          product.save
          expect(product.call_limitation_info).to be_nil
        end
      end

      context "native type is call" do
        before { product.native_type = Link::NATIVE_TYPE_CALL }

        it "creates a call limitations record" do
          product.save!
          call_limitation_info = product.call_limitation_info
          expect(call_limitation_info.minimum_notice_in_minutes).to eq(CallLimitationInfo::DEFAULT_MINIMUM_NOTICE_IN_MINUTES)
          expect(call_limitation_info.maximum_calls_per_day).to be_nil
        end
      end
    end

    describe "initialize_duration_variant_category_for_calls!" do
      context "native type is call" do
        let(:call) { create(:call_product) }

        it "creates a duration variant category" do
          expect(call.variant_categories.count).to eq(1)
          expect(call.variant_categories.first.title).to eq("Duration")
        end
      end

      context "native type is not call" do
        let(:product) { create(:physical_product) }

        it "does not create a duration variant category" do
          expect(product.variant_categories.count).to eq(0)
        end
      end
    end


    describe "delete_unused_prices" do
      let!(:product) { create(:product, purchase_type: :buy_and_rent, price_cents: 500, rental_price_cents: 100) }
      let(:buy_price) { product.prices.is_buy.first }
      let(:rental_price) { product.prices.is_rental.first }

      context "when switching to a buy_only product" do
        it "deletes any rental prices" do
          expect do
            product.update!(purchase_type: :buy_only)
          end.to change { product.prices.alive.count }.from(2).to(1)
             .and change { product.prices.alive.is_rental.count }.from(1).to(0)

          expect(rental_price).to be_deleted
        end
      end

      context "when switching to a rent_only product" do
        it "deletes any buy prices" do
          expect do
            product.update!(purchase_type: :rent_only)
          end.to change { product.prices.alive.count }.from(2).to(1)
             .and change { product.prices.alive.is_buy.count }.from(1).to(0)

          expect(buy_price).to be_deleted
        end
      end

      context "when switching to a buy_and_rent product" do
        it "does nothing" do
          buy_product = create(:product, purchase_type: :buy_only)
          expect do
            buy_product.update!(purchase_type: :buy_and_rent)
          end.not_to change { buy_product.prices.alive.count }

          rental_product = create(:product, purchase_type: :rent_only, rental_price_cents: 100)
          expect do
            rental_product.update!(purchase_type: :buy_and_rent)
          end.not_to change { rental_product.prices.alive.count }
        end
      end

      context "when leaving purchase_type unchanged" do
        it "does not run the callback" do
          expect(product).not_to receive(:delete_unused_prices)

          product.update!(purchase_type: :buy_and_rent)
        end
      end
    end

    describe "adding to profile sections" do
      it "adds newly created products to all sections that have add_new_products set" do
        seller = create(:user)
        default_sections = create_list(:seller_profile_products_section, 2, seller:)
        other_sections = create_list(:seller_profile_products_section, 2, seller:, add_new_products: false)
        link = create(:product, user: seller)

        default_sections.each do |section|
          expect(section.reload.shown_products).to include link.id
        end
        other_sections.each do |section|
          expect(section.reload.shown_products).to_not include link.id
        end
      end
    end
  end

  describe "associations" do
    it { is_expected.to have_many(:self_service_affiliate_products).with_foreign_key(:product_id) }

    describe "#confirmed_collaborators" do
      it "returns all confirmed collaborators" do
        product = create(:product)

        # Those who have not accepted the invitation are not included,
        # regardless of self-deleted status.
        create(:collaborator, :with_pending_invitation, products: [product], deleted_at: 1.minute.ago)
        collaborator = create(:collaborator, :with_pending_invitation, products: [product])
        expect(product.confirmed_collaborators).to be_empty

        # Those who have accepted the invitation are included...
        collaborator.collaborator_invitation.destroy!
        expect(product.confirmed_collaborators).to contain_exactly(collaborator)

        # ...regardless of self-deleted status.
        collaborator.mark_deleted!
        expect(product.confirmed_collaborators).to contain_exactly(collaborator)
      end
    end

    describe "#collaborator" do
      it "returns the live collaborator" do
        product = create(:product)
        create(:collaborator, products: [product], deleted_at: 1.minute.ago)
        collaborator = create(:collaborator, products: [product])

        expect(product.collaborator).to eq collaborator
      end
    end

    describe "#collaborator_for_display" do
      it "returns the collaborating user if they should be shown as a co-creator" do
        product = create(:product)
        collaborator = create(:collaborator)

        expect(product.collaborator_for_display).to eq nil

        collaborator.products = [product]
        allow_any_instance_of(Collaborator).to receive(:show_as_co_creator_for_product?).and_return(true)
        expect(product.collaborator_for_display).to eq collaborator.affiliate_user

        allow_any_instance_of(Collaborator).to receive(:show_as_co_creator_for_product?).and_return(false)
        expect(product.collaborator_for_display).to eq nil
      end
    end

    describe "#current_base_variants" do
      it "returns variants and SKUs that have not been deleted and whose variant category has not been deleted" do
        product = create(:physical_product)

        # live category with 1 live variant, 1 deleted variant
        size_category = create(:variant_category, link: product, title: "Size")
        small_variant = create(:variant, variant_category: size_category, name: "Small")
        create(:variant, variant_category: size_category, name: "Large", deleted_at: Time.current)

        # deleted category with 1 live variant, 1 deleted variant
        color_category = create(:variant_category, link: product, title: "Color", deleted_at: Time.current)
        create(:variant, variant_category: color_category, name: "Red")
        create(:variant, variant_category: color_category, name: "Blue", deleted_at: Time.current)

        # 2 live SKUs, 1 deleted SKU
        default_sku = product.skus.is_default_sku.first
        live_sku = create(:sku, link: product, name: "Small-Red")
        create(:sku, link: product, name: "Large-Blue", deleted_at: Time.current)

        expect(product.current_base_variants).to match_array [small_variant, live_sku, default_sku]
      end
    end

    describe "#public_files" do
      it "returns all public files associated with the product" do
        product = create(:product)
        public_file = create(:public_file, resource: product)
        deleted_public_file = create(:public_file, resource: product, deleted_at: Time.current)
        _another_product_public_file = create(:public_file)

        expect(product.public_files).to eq([public_file, deleted_public_file])
      end
    end

    describe "#alive_public_files" do
      it "returns all alive public files associated with the product" do
        product = create(:product)
        public_file = create(:public_file, resource: product)
        _deleted_public_file = create(:public_file, resource: product, deleted_at: Time.current)
        _another_product_public_file = create(:public_file)

        expect(product.alive_public_files).to eq([public_file])
      end
    end

    describe "#communities" do
      it "returns all communities associated with the product" do
        product = create(:product)
        communities = [
          create(:community, resource: product, deleted_at: 1.minute.ago),
          create(:community, resource: product),
        ]
        expect(product.communities).to match_array(communities)
      end
    end

    describe "#active_community" do
      it "returns the live community" do
        product = create(:product)
        create(:community, resource: product, deleted_at: 1.minute.ago)
        community = create(:community, resource: product)

        expect(product.active_community).to eq(community)
      end
    end
  end

  describe "scopes" do
    let(:user) { create(:user) }

    describe "alive" do
      before do
        create(:product, user:, name: "alive")
        create(:product, user:, purchase_disabled_at: Time.current)
        create(:product, user:, deleted_at: Time.current)
        create(:product, user:, banned_at: Time.current)
      end

      it "returns the correct products do" do
        expect(user.links.alive.count).to eq 1
        expect(user.links.alive.first.name).to eq "alive"
      end
    end

    describe "visible" do
      let!(:deleted_product) { create(:product, user:, deleted_at: Time.current) }
      let!(:product) { create(:product, user:) }
      let!(:archived_product) { create(:product, user:, archived: true) }

      it "returns the correct products" do
        expect(user.links.visible.count).to eq 2
        expect(user.links.visible).to eq [product, archived_product]
      end
    end

    describe "visible_and_not_archived" do
      let!(:deleted_product) { create(:product, user:, deleted_at: Time.current) }
      let!(:product) { create(:product, user:) }
      let!(:archived_product) { create(:product, user:, archived: true) }

      it "returns the correct products" do
        expect(user.links.visible_and_not_archived.count).to eq 1
        expect(user.links.visible_and_not_archived).to eq [product]
      end
    end

    describe "by_general_permalink" do
      before do
        @product_1 = create(:product, unique_permalink: "xxx")
        @product_2 = create(:product, unique_permalink: "yyy", custom_permalink: "custom")
        @product_3 = create(:product, unique_permalink: "zzz", custom_permalink: "awesome")
      end

      it "matches products by unique permalink" do
        expect(Link.by_general_permalink("xxx")).to match_array([@product_1])
      end

      it "matches products by custom permalink" do
        expect(Link.by_general_permalink("custom")).to match_array([@product_2])
      end

      it "does not match products if empty permalink is passed" do
        # Making sure this does not match products without a custom permalink
        expect(Link.by_general_permalink(nil)).to be_empty
        expect(Link.by_general_permalink("")).to be_empty
      end
    end

    describe "by_unique_permalinks" do
      before do
        @product_1 = create(:product, unique_permalink: "xxx")
        @product_2 = create(:product, unique_permalink: "yyy", custom_permalink: "custom")
        @product_3 = create(:product, unique_permalink: "zzz", custom_permalink: "awesome")
      end

      it "matches products by unique permalink" do
        expect(Link.by_unique_permalinks(["xxx", "yyy"])).to match_array([@product_1, @product_2])
      end

      it "does not match products by custom permalink" do
        expect(Link.by_unique_permalinks(["awesome", "custom"])).to be_empty
      end

      it "returns matched products and ignores permalinks that did not match" do
        expect(Link.by_unique_permalinks(["xxx", "custom"])).to match_array([@product_1])
      end

      it "does not match any products if no permalinks are provided" do
        expect(Link.by_unique_permalinks([])).to be_empty
      end
    end

    describe "unpublished" do
      before do
        create(:product, user:)
        create(:product, user:, purchase_disabled_at: Time.current, name: "unpublished")
      end

      it "returns the correct products do" do
        expect(user.links.where.not(purchase_disabled_at: nil).count).to eq 1
        expect(user.links.where.not(purchase_disabled_at: nil).first.name).to eq "unpublished"
      end
    end

    describe "publish!" do
      before do
        @user = create(:user)
        @merchant_account = create(:merchant_account_stripe, user: @user)
        @product = create(:product_with_pdf_file, purchase_disabled_at: Time.current, user: @user)
      end

      it "publishes the product" do
        expect do
          @product.publish!
        end.to change { @product.reload.purchase_disabled_at }.to(nil)
      end

      context "when the user has not confirmed their email address" do
        before do
          @user.update!(confirmed_at: nil)
        end

        it "raises a Link::LinkInvalid error" do
          expect do
            @product.publish!
          end.to raise_error(Link::LinkInvalid)
          expect(@product.reload.purchase_disabled_at).to_not be(nil)
          expect(@product.errors.full_messages.to_sentence).to eq("You have to confirm your email address before you can do that.")
        end
      end

      context "when a bundle has no alive products" do
        before do
          @product.update!(is_bundle: true)
          create(:bundle_product, bundle: @product, product: create(:product, user: @user), deleted_at: Time.current)
        end

        it "raises a Link::LinkInvalid error" do
          expect do
            @product.publish!
          end.to raise_error(ActiveRecord::RecordInvalid)
          expect(@product.reload.purchase_disabled_at).to_not be(nil)
          expect(@product.errors.full_messages.to_sentence).to eq("Bundles must have at least one product.")
        end
      end

      context "when the seller has universal affiliates" do
        it "associates those affiliates with the product and notifies them" do
          direct_affiliate = create(:direct_affiliate, seller: @user, apply_to_all_products: true)

          expect do
            @product.publish!
          end.to have_enqueued_mail(AffiliateMailer, :notify_direct_affiliate_of_new_product).with(direct_affiliate.id, @product.id)

          expect(@product.reload.direct_affiliates).to match_array [direct_affiliate]
          expect(direct_affiliate.reload.products).to match_array [@product]
        end

        context "who are already associated with the product" do
          it "does not add or notify them" do
            direct_affiliate = create(:direct_affiliate, seller: @user, apply_to_all_products: true, products: [@product])

            expect do
              @product.publish!
            end.to_not have_enqueued_mail(AffiliateMailer, :notify_direct_affiliate_of_new_product).with(direct_affiliate.id, @product.id)

            expect(@product.reload.direct_affiliates).to match_array [direct_affiliate]
            expect(direct_affiliate.reload.products).to match_array [@product]
          end
        end

        context "when affiliate has been removed" do
          it "does not add or notify them" do
            direct_affiliate = create(:direct_affiliate, seller: @user, apply_to_all_products: true)
            direct_affiliate.mark_deleted!

            expect do
              @product.publish!
            end.to_not have_enqueued_mail(AffiliateMailer, :notify_direct_affiliate_of_new_product).with(direct_affiliate.id, @product.id)

            expect(@product.reload.direct_affiliates).to be_empty
            expect(direct_affiliate.reload.products).to be_empty
          end
        end
      end

      context "video transcoding" do
        before do
          @video_link = create(:product, draft: true, user: @user)
          allow(@user).to receive(:auto_transcode_videos?).and_return(true)
        end

        it "doesn't transcode video when the link is draft" do
          video_file = create(:product_file, link_id: @video_link.id, url: "https://s3.amazonaws.com/gumroad-specs/attachments/2/original/chapter2.mp4")

          expect(TranscodeVideoForStreamingWorker).not_to have_enqueued_sidekiq_job(video_file.id, video_file.class.name)
        end

        it "transcodes video files on publishing the product only if `queue_for_transcoding?` is true for the product file" do
          video_file_1 = create(:product_file, link_id: @video_link.id, url: "https://s3.amazonaws.com/gumroad-specs/attachments/2/original/chapter2.mp4")
          video_file_2 = create(:product_file, link_id: @video_link.id, url: "https://s3.amazonaws.com/gumroad-specs/attachments/2/original/chapter3.mp4")
          video_file_3 = create(:product_file, link_id: @video_link.id, url: "https://s3.amazonaws.com/gumroad-specs/attachments/2/original/chapter4.mp4")
          video_file_3.delete!

          @video_link.publish!
          expect(TranscodeVideoForStreamingWorker).to_not have_enqueued_sidekiq_job(video_file_1.id, video_file_1.class.name)
          expect(TranscodeVideoForStreamingWorker).to_not have_enqueued_sidekiq_job(video_file_2.id, video_file_2.class.name)
          expect(TranscodeVideoForStreamingWorker).to_not have_enqueued_sidekiq_job(video_file_3.id, video_file_3.class.name)
          @video_link.unpublish!

          allow_any_instance_of(ProductFile).to receive(:queue_for_transcoding?).and_return(true)
          @video_link.publish!
          expect(TranscodeVideoForStreamingWorker).to have_enqueued_sidekiq_job(video_file_1.id, video_file_1.class.name)
          expect(TranscodeVideoForStreamingWorker).to have_enqueued_sidekiq_job(video_file_2.id, video_file_2.class.name)
          expect(TranscodeVideoForStreamingWorker).to_not have_enqueued_sidekiq_job(video_file_3.id, video_file_3.class.name)
        end

        describe "published links" do
          before do
            allow(FFMPEG::Movie).to receive(:new) do
              double.tap do |movie_double|
                allow(movie_double).to receive(:duration).and_return(13)
                allow(movie_double).to receive(:frame_rate).and_return(60)
                allow(movie_double).to receive(:height).and_return(240)
                allow(movie_double).to receive(:width).and_return(320)
                allow(movie_double).to receive(:bitrate).and_return(125_779)
              end
            end

            @s3_double = double
            allow(@s3_double).to receive(:content_length).and_return(10_000)
            allow(@s3_double).to receive(:get) do |options|
              File.open(options[:response_target], "w+") do |f|
                f.write("")
              end
            end

            create(:product_file, link: @video_link, url: "https://s3.amazonaws.com/gumroad-specs/attachment/pencil.png")
            @video_link.publish!
          end

          it "transcodes video when the link is already published" do
            allow_any_instance_of(Link).to receive(:auto_transcode_videos?).and_return(true)
            video_file = create(:product_file, link_id: @video_link.id, url: "https://s3.amazonaws.com/gumroad-specs/attachments/2/original/chapter2.mp4")
            allow(video_file).to receive(:s3_object).and_return(@s3_double)
            allow(video_file).to receive(:confirm_s3_key!)
            video_file.analyze

            expect(TranscodeVideoForStreamingWorker).to have_enqueued_sidekiq_job(video_file.id, video_file.class.name)
          end

          it "doesn't transcode when the link is unpublished" do
            @video_link.unpublish!

            video_file = create(:product_file, link_id: @video_link.id, url: "https://s3.amazonaws.com/gumroad-specs/attachments/2/original/chapter2.mp4")
            allow(video_file).to receive(:s3_object).and_return(@s3_double)
            allow(video_file).to receive(:confirm_s3_key!)
            video_file.analyze

            expect(TranscodeVideoForStreamingWorker).not_to have_enqueued_sidekiq_job(video_file.id, video_file.class.name)
          end
        end

        describe "auto transcode videos" do
          before do
            @video_file = create(:streamable_video, :analyze)
            @product = @video_file.link
          end

          context "when auto-transcode is enabled" do
            before do
              allow(@product).to receive(:auto_transcode_videos?).and_return(true)
            end

            it "transcodes the videos" do
              @product.publish!

              expect(TranscodeVideoForStreamingWorker).to have_enqueued_sidekiq_job(@video_file.id, @video_file.class.name)
            end
          end

          context "when auto-transcode is disabled" do
            before do
              allow(@product).to receive(:auto_transcode_videos?).and_return(false)
            end

            it "doesn't transcode the video" do
              expect do
                @product.publish!
              end.not_to change { TranscodeVideoForStreamingWorker.jobs.size }
            end

            it "enables transcode on purchase" do
              @product.update_attribute(:transcode_videos_on_purchase, false)

              expect do
                @product.publish!
              end.to change { @product.transcode_videos_on_purchase? }.from(false).to(true)
            end
          end
        end
      end

      context "Merchant migration enabled" do
        before do
          Feature.activate_user(:merchant_migration, @user)
        end

        after do
          Feature.deactivate_user(:merchant_migration, @user)
        end

        it "allows publishing if grandfathered account" do
          @user.save!

          expect do
            @product.publish!
          end.to change { @product.reload.purchase_disabled_at }.to(nil)
        end

        it "allows publishing if new account and has a valid merchant account connected" do
          @user.save!

          expect do
            @product.publish!
          end.to change { @product.reload.purchase_disabled_at }.to(nil)
        end
      end

      context "when new account and no valid merchant account connected" do
        before do
          @user.check_merchant_account_is_linked = true
          @user.payment_address = nil
          @user.save!
          @merchant_account.mark_deleted!
        end

        it "raises a Link::LinkInvalid error" do
          expect do
            @product.publish!
          end.to raise_error(Link::LinkInvalid)
          expect(@product.reload.purchase_disabled_at).to_not be(nil)
        end

        context "when the seller has universal affiliates" do
          it "does not associate those affiliates with the product and notifies them" do
            direct_affiliate = create(:direct_affiliate, seller: @user, apply_to_all_products: true)

            expect do
              @product.publish! rescue nil
            end.to_not have_enqueued_mail(AffiliateMailer, :notify_direct_affiliate_of_new_product).with(direct_affiliate.id, @product.id)

            expect(@product.reload.direct_affiliates).to match_array []
            expect(direct_affiliate.reload.products).to match_array []
          end
        end
      end
    end

    describe "deleted" do
      before do
        create(:product, user:)
        create(:product, user:, deleted_at: Time.current, name: "deleted")
      end

      it "returns the correct products do" do
        expect(user.links.deleted.count).to eq 1
        expect(user.links.deleted.first.name).to eq "deleted"
      end
    end

    describe "paid_downloads" do
      before do
        @product = create(:product, user:, name: "paid_download")
        3.times { create(:purchase, link: @product, purchase_state: "successful") }
        create(:product, user:)
      end

      it "returns the correct products do" do
        expect(user.links.has_paid_sales.count).to eq 1
        expect(user.links.has_paid_sales.first.id).to eq @product.id
      end
    end

    describe "not_draft" do
      before do
        @product = create(:product, user:, draft: false)
        create(:product, user:, draft: true)
      end

      it "returns the correct products do" do
        expect(user.links.not_draft.count).to eq 1
        expect(user.links.not_draft.first.id).to eq @product.id
      end
    end

    describe "created_between" do
      before do
        @product = create(:product, user:, created_at: 2.days.ago)
        create(:product, user:, created_at: 6.days.ago)
      end

      it "returns the correct products do" do
        expect(user.links.created_between(3.days.ago..Time.current).count).to eq 1
        user.links.created_between(3.days.ago..Time.current).first.id == @product.id
      end
    end

    describe "has_paid_sales_between" do
      before do
        @product_with_recent_sales = create(:product)
        @product_no_recent_sales = create(:product)

        create(:purchase, link: @product_with_recent_sales, created_at: 1.minute.ago)
        create(:purchase, link: @product_no_recent_sales, created_at: 2.weeks.ago)
      end

      it "returns link with sales made after 1.week.ago" do
        expect(Link.has_paid_sales_between(1.week.ago, Time.current)).to include @product_with_recent_sales
      end

      it "does not return link with sales from before that" do
        expect(Link.has_paid_sales_between(1.week.ago, Time.current)).to_not include @product_no_recent_sales
      end
    end

    describe "membership" do
      before do
        @membership = create(:subscription_product)
        create(:product)
      end

      it "returns memberships" do
        expect(Link.membership).to eq([@membership])
      end
    end

    describe "non_membership" do
      before do
        @product = create(:product)
        create(:subscription_product)
      end

      it "returns memberships" do
        expect(Link.non_membership).to eq([@product])
      end
    end

    describe "collabs_as_collaborator" do
      it "returns products that the user is a collaborator on" do
        user = create(:user)

        # collabs I created
        own_collabs = create_list(:product, 3, user:)
        own_collabs.each { create(:product_affiliate, product: _1, affiliate: create(:collaborator, seller: user)) }

        # products I'm a collaborator on
        seller = create(:user)
        seller_collabs = create_list(:product, 2, user: seller)
        collaborator = create(:collaborator, affiliate_user: user, seller: seller)
        seller_collabs.each { create(:product_affiliate, product: _1, affiliate: collaborator) }

        # products I'm no longer a collaborator on
        seller_old_collab = create(:product, user: seller)
        collaborator = create(:collaborator, affiliate_user: user, seller: seller, deleted_at: 1.day.ago)
        create(:product_affiliate, product: seller_old_collab, affiliate: collaborator)

        # products others are collaborators on
        seller_other_collabs = create_list(:product, 2, user: seller)
        seller_other_collabs.each { create(:product_affiliate, product: _1, affiliate: create(:collaborator, seller: seller)) }

        # products I'm invited to collaborate on
        inviter = create(:user)
        create(
          :collaborator,
          :with_pending_invitation,
          affiliate_user: user,
          seller: inviter,
          products: create_list(:product, 2, user: inviter, is_collab: true)
        )

        # non-collab products
        create(:product, user:)
        create(:product, user: seller)

        # collab products with prior affiliate associations
        other_collabs = create_list(:product, 2, user: seller, is_collab: true)
        create(:direct_affiliate, affiliate_user: user, seller: seller, products: [other_collabs.first])
        create(:product_affiliate, affiliate: user.global_affiliate, product: other_collabs.last)

        expect(Link.collabs_as_collaborator(user).pluck(:id)).to match_array(seller_collabs.pluck(:id))
      end
    end

    describe "collabs_as_seller_or_collaborator" do
      it "returns products that the user is a collaborator on and collabs they've created" do
        user = create(:user)

        # collabs I created
        own_collabs = create_list(:product, 3, user:)
        own_collabs.each { create(:product_affiliate, product: _1, affiliate: create(:collaborator, seller: user)) }

        # products I'm a collaborator on
        seller1 = create(:user)
        seller1_collabs = create_list(:product, 2, user: seller1)
        collaborator = create(:collaborator, affiliate_user: user, seller: seller1)
        seller1_collabs.each { create(:product_affiliate, product: _1, affiliate: collaborator) }

        seller2 = create(:user)
        seller2_collab = create(:product, user: seller2)
        collaborator = create(:collaborator, affiliate_user: user, seller: seller2)
        create(:product_affiliate, product: seller2_collab, affiliate: collaborator)

        # products I'm no longer a collaborator on
        seller1_old_collab = create(:product, user: seller1)
        collaborator = create(:collaborator, affiliate_user: user, seller: seller1, deleted_at: 1.day.ago)
        create(:product_affiliate, product: seller1_old_collab, affiliate: collaborator)

        # products others are collaborators on
        seller1_other_collabs = create_list(:product, 2, user: seller1)
        seller1_other_collabs.each { create(:product_affiliate, product: _1, affiliate: create(:collaborator, seller: seller1)) }

        seller2_other_collab = create(:product, user: seller2)
        create(:product_affiliate, product: seller2_other_collab, affiliate: create(:collaborator, seller: seller2))

        # products I'm invited to collaborate on
        inviter = create(:user)
        create(
          :collaborator,
          :with_pending_invitation,
          affiliate_user: user,
          seller: inviter,
          products: create_list(:product, 2, user: inviter, is_collab: true)
        )

        # non-collab products
        create(:product, user:)
        create(:product, user: seller1)
        create(:product, user: seller2)
        create(:direct_affiliate, affiliate_user: user, products: [create(:product)])

        # collab products with prior affiliate associations
        other_collabs = create_list(:product, 2, user: seller1, is_collab: true)
        create(:direct_affiliate, affiliate_user: user, seller: seller1, products: [other_collabs.first])
        create(:product_affiliate, affiliate: user.global_affiliate, product: other_collabs.last)

        collab_ids = own_collabs.pluck(:id) + seller1_collabs.pluck(:id) + [seller2_collab.id]

        expect(Link.collabs_as_seller_or_collaborator(user).pluck(:id)).to match_array(collab_ids)
      end
    end

    describe "for_balance_page" do
      it "returns all the user's own products and collab products" do
        user = create(:user)

        # collabs I created
        own_collabs = create_list(:product, 3, user:)
        own_collabs.each { create(:product_affiliate, product: _1, affiliate: create(:collaborator, seller: user)) }

        # products I'm a collaborator on
        seller = create(:user)
        seller_collabs = create_list(:product, 2, user: seller)
        collaborator = create(:collaborator, affiliate_user: user, seller: seller)
        seller_collabs.each { create(:product_affiliate, product: _1, affiliate: collaborator) }

        # products I'm no longer a collaborator on
        seller_old_collab = create(:product, user: seller)
        collaborator = create(:collaborator, affiliate_user: user, seller: seller, deleted_at: 1.day.ago)
        create(:product_affiliate, product: seller_old_collab, affiliate: collaborator)

        # products others are collaborators on
        seller_other_collabs = create_list(:product, 2, user: seller)
        seller_other_collabs.each { create(:product_affiliate, product: _1, affiliate: create(:collaborator, seller: seller)) }

        # non-collab products
        non_collabs = create_list(:product, 2, user:)
        create(:product, user: seller)

        # collab products with prior affiliate associations
        other_collabs = create_list(:product, 2, user: seller, is_collab: true)
        create(:direct_affiliate, affiliate_user: user, seller: seller, products: [other_collabs.first])
        create(:product_affiliate, affiliate: user.global_affiliate, product: other_collabs.last)

        product_ids = (own_collabs + seller_collabs + non_collabs).map(&:id)

        expect(Link.for_balance_page(user).pluck(:id)).to match_array(product_ids)
      end
    end

    describe "not_call" do
      let!(:call_product) { create(:call_product) }
      let!(:product) { create(:product) }

      it "returns products that are not calls" do
        expect(Link.not_call).to contain_exactly(product)
      end
    end

    describe "can_be_bundle" do
      let!(:bundle) { create(:product, :bundle) }
      let!(:membership_product) { create(:membership_product) }
      let!(:versioned_product) { create(:product_with_digital_versions) }
      let!(:call_product) { create(:call_product) }
      let!(:product) { create(:product) }

      it "returns products that can be bundles" do
        expect(Link.can_be_bundle).to match_array([product, bundle, *bundle.bundle_products.map(&:product)])
      end
    end

    describe "with_latest_product_cached_values" do
      it "joins a product_cached_values row for each product" do
        user = create(:user)
        product_1 = create(:product, user:)
        create(:product_cached_value, product: product_1)
        product_1_cached_value = create(:product_cached_value, product: product_1)
        product_2 = create(:product, user:)
        product_2_cached_value = create(:product_cached_value, product: product_2)
        product_3 = create(:product, user:)

        results = Link.where(user:).with_latest_product_cached_values(user_id: user.id).select("links.id, latest_product_cached_values.id as lpcvid").order(:id)
        expect(results[0].id).to eq(product_1.id)
        expect(results[0].lpcvid).to eq(product_1_cached_value.id)
        expect(results[1].id).to eq(product_2.id)
        expect(results[1].lpcvid).to eq(product_2_cached_value.id)
        expect(results[2].id).to eq(product_3.id)
        expect(results[2].lpcvid).to eq(nil)
      end
    end
  end

  describe "custom_permalink" do
    describe "validity" do
      it "is valid if it has numbers" do
        expect(build(:product, custom_permalink: "a23f").valid?).to be(true)
      end

      it "is valid is it has letters" do
        expect(build(:product, custom_permalink: "asdfsdf").valid?).to be(true)
      end

      it "is valid if it has _" do
        expect(build(:product, custom_permalink: "asdf_asdf").valid?).to be(true)
      end

      it "is valid if it has -" do
        expect(build(:product, custom_permalink: "asdf-asdf").valid?).to be(true)
      end

      it "is invalid if it has &" do
        expect(build(:product, custom_permalink: "asdf&asdf").valid?).to be(false)
      end

      it "is invalid if it has *" do
        expect(build(:product, custom_permalink: "asdf*23sdf").valid?).to be(false)
      end

      it "is invalid if it has !" do
        expect(build(:product, custom_permalink: "asdf!213").valid?).to be(false)
      end

      it "is invalid if duplicates a custom permalink of another product by the same user" do
        user = create(:user)
        create(:product, user:, custom_permalink: "custom")

        expect(build(:product, user:, custom_permalink: "custom").valid?).to be(false)
      end

      it "is invalid if duplicates a unique permalink of another product by the same user" do
        user = create(:user)
        create(:product, user:, unique_permalink: "abc")

        expect(build(:product, user:, custom_permalink: "abc").valid?).to be(false)
      end

      it "is valid if duplicates a unique permalink of another user's product" do
        create(:product, user: create(:user), unique_permalink: "abc")

        expect(build(:product, user: create(:user), custom_permalink: "abc").valid?).to be(true)
      end

      it "is valid if duplicates a custom permalink of another user's product" do
        create(:product, user: create(:user), custom_permalink: "custom")

        expect(build(:product, user: create(:user), custom_permalink: "custom").valid?).to be(true)
      end

      describe "uniqueness validation for licensed products" do
        before do
          @force_product_id_timestamp = Time.current
          @licensed = true
          @other_product = create(:product, is_licensed: true, custom_permalink: "abc", unique_permalink: "xyz", created_at: @force_product_id_timestamp - 1.day)

          $redis.set(RedisKey.force_product_id_timestamp, @force_product_id_timestamp)
        end

        shared_examples_for "product is valid" do
          it "marks the product as valid" do
            product1 = create(:product, is_licensed: @licensed, created_at: @created_at_timestamp)
            expect(product1.update!(custom_permalink: "abc")).to eq true

            product2 = create(:product, is_licensed: @licensed, created_at: @created_at_timestamp)
            expect(product2.update!(custom_permalink: "xyz")).to eq true
          end
        end

        context "when the product is licensed" do
          context "when product is not persisted" do
            it "marks the product as valid" do
              expect(build(:product, is_licensed: true, custom_permalink: "abc").valid?).to be(true)
              expect(build(:product, is_licensed: true, custom_permalink: "xyz").valid?).to be(true)
            end
          end

          context "when the product is persisted" do
            context "when the created_at is after force_product_id_timestamp" do
              before do
                @created_at_timestamp = @force_product_id_timestamp + 1.day
              end

              it_behaves_like "product is valid"
            end

            context "when the created_at is before the force_product_id_timestamp" do
              before do
                @created_at_timestamp = @force_product_id_timestamp - 1.day
              end

              context "when the product is not licensed" do
                before do
                  @licensed = false
                end

                it_behaves_like "product is valid"
              end

              context "when other sellers have licensed products with same custom or unique permalinks" do
                context "when products of other sellers were created before force_product_id_timestamp" do
                  it "marks the product as invalid" do
                    product1 = create(:product, is_licensed: true, created_at: @created_at_timestamp)
                    expect(product1.update(custom_permalink: "abc")).to eq false
                    expect(product1.errors.full_messages.to_sentence).to eq "Custom permalink has already been taken"

                    product2 = create(:product, is_licensed: true, created_at: @created_at_timestamp)
                    expect(product2.update(custom_permalink: "xyz")).to eq false
                    expect(product2.errors.full_messages.to_sentence).to eq "Custom permalink has already been taken"
                  end
                end

                context "when products of other sellers were created after force_product_id_timestamp" do
                  before do
                    @other_product.update!(created_at: @force_product_id_timestamp + 1.day)
                  end

                  it_behaves_like "product is valid"
                end
              end
            end
          end
        end
      end
    end

    describe "is_licensed" do
      describe "validation for products with custom permalinks overlap" do
        before do
          @force_product_id_timestamp = Time.current
          @licensed = true
          @other_product = create(:product, is_licensed: true, custom_permalink: "abc", unique_permalink: "xyz", created_at: @force_product_id_timestamp - 1.day)

          $redis.set(RedisKey.force_product_id_timestamp, @force_product_id_timestamp)
        end

        shared_examples_for "product is valid" do
          it "marks the product as valid" do
            product1 = create(:product, custom_permalink: "abc", created_at: @created_at_timestamp)
            expect(product1.update!(is_licensed: @licensed)).to eq true

            product2 = create(:product, custom_permalink: "xyz", created_at: @created_at_timestamp)
            expect(product2.update!(is_licensed: @licensed)).to eq true
          end
        end

        context "when the product is licensed" do
          context "when product is not persisted" do
            it "marks the product as valid" do
              expect(build(:product, is_licensed: true, custom_permalink: "abc").valid?).to be(true)
              expect(build(:product, is_licensed: true, custom_permalink: "xyz").valid?).to be(true)
            end
          end

          context "when the product is persisted" do
            context "when the created_at is after force_product_id_timestamp" do
              before do
                @created_at_timestamp = @force_product_id_timestamp + 1.day
              end

              it_behaves_like "product is valid"
            end

            context "when the created_at is before the force_product_id_timestamp" do
              before do
                @created_at_timestamp = @force_product_id_timestamp - 1.day
              end

              context "when the product is not licensed" do
                before do
                  @licensed = false
                end

                it_behaves_like "product is valid"
              end

              context "when other sellers have licensed products with same custom or unique permalinks" do
                context "when products of other sellers were created before force_product_id_timestamp" do
                  it "marks the product as invalid" do
                    product1 = create(:product, custom_permalink: "abc", created_at: @created_at_timestamp)
                    expect(product1.update(is_licensed: true)).to eq false
                    expect(product1.errors.full_messages.to_sentence).to eq "Custom permalink has already been taken"

                    product2 = create(:product, custom_permalink: "xyz", created_at: @created_at_timestamp)
                    expect(product2.update(is_licensed: true)).to eq false
                    expect(product2.errors.full_messages.to_sentence).to eq "Custom permalink has already been taken"
                  end
                end

                context "when products of other sellers were created after force_product_id_timestamp" do
                  before do
                    @other_product.update!(created_at: @force_product_id_timestamp + 1.day)
                  end

                  it_behaves_like "product is valid"
                end
              end
            end
          end
        end
      end
    end

    it "is case-insensitive" do
      product = create(:product, custom_permalink: "custom")

      expect(Link.find_by(custom_permalink: "custom")).to eq(product)
      expect(Link.find_by(custom_permalink: "CUSTOM")).to eq(product)
    end
  end

  describe "unique_permalink" do
    it "is invalid if it has numbers in it" do
      expect(build(:product, unique_permalink: "a23f").valid?).to be(false)
    end

    it "is valid with underscores" do
      expect(build(:product, unique_permalink: "a_b_c_d").valid?).to be(true)
    end

    it "is case-insensitive" do
      product = create(:product, unique_permalink: "abc")

      expect(Link.find_by(unique_permalink: "abc")).to eq(product)
      expect(Link.find_by(unique_permalink: "ABC")).to eq(product)
    end

    describe "automatic generation of unique permalinks" do
      describe "conflicts with other unique permalinks" do
        before do
          # Take up all possible one-letter unique permalinks
          ("a".."z").to_a.each { |ch| create :product, unique_permalink: ch }
        end

        it "generates the shortest possible permalink that does not conflict with other unique permalinks" do
          # Does not take any of the one-letter permalinks
          expect(create(:product).unique_permalink.length).to eq(2)
        end
      end

      describe "conflicts with custom permalinks by other users" do
        before do
          # Take up all possible one-letter custom permalinks (and make sure no one-letter unique permalinks)
          ("a".."z").to_a.each do |ch|
            create :product, unique_permalink: ch * 2, custom_permalink: ch
          end
        end

        it "generates the shortest possible permalink that may conflict with custom permalinks" do
          expect(create(:product).unique_permalink.length).to eq(1)
        end
      end

      describe "conflicts with custom permalinks by the same user" do
        let(:user) { create(:user) }

        before do
          # Take up all possible one-letter custom permalinks (and make sure no one-letter unique permalinks)
          ("a".."z").to_a.each do |ch|
            create :product, user:, unique_permalink: ch * 2, custom_permalink: ch
          end
        end

        it "generates the shortest possible permalink that does not conflict with custom permalinks" do
          expect(create(:product, user:).unique_permalink.length).not_to eq(1)
        end
      end

      describe "case sensitivity" do
        before do
          # Take up all possible one-letter permalinks with uppercase chars
          ("A".."Z").to_a.each { |ch| create :product, unique_permalink: ch }
        end

        it "does not duplicate uppercase permalinks and generates a lowercase permalink" do
          product = create(:product)

          expect(product.unique_permalink).to match(/\A[a-z]+\z/)
          expect(product.unique_permalink.length).to eq(2)
        end
      end
    end
  end

  describe "#fetch_leniently" do
    let!(:user_1) { create(:user) }
    let!(:product_1) { create(:product, user: user_1, unique_permalink: "aaa") }
    let!(:product_2) { create(:product, user: user_1, unique_permalink: "bbb", custom_permalink: "custom") }
    let!(:product_3) { create(:product, user: user_1, unique_permalink: "ccc", custom_permalink: "no-longer-alive", deleted_at: Time.current) }

    let!(:user_2) { create(:user) }
    let!(:product_4) { create(:product, user: user_2, unique_permalink: "ddd") }
    let!(:product_5) { create(:product, user: user_2, unique_permalink: "eee", custom_permalink: "awesome") }
    let!(:product_6) { create(:product, user: user_2, unique_permalink: "fff", custom_permalink: "custom") }

    context "by unique permalink" do
      it "fetches a product by unique permalink" do
        expect(Link.fetch_leniently("aaa")).to eq(product_1)
      end

      it "scopes search to specific user if provided" do
        expect(Link.fetch_leniently("aaa", user: user_1)).to eq(product_1)
        expect(Link.fetch_leniently("aaa", user: user_2)).to eq(nil)
      end

      it "does not fetch a deleted product" do
        expect(Link.fetch_leniently("ccc")).to eq(nil)
      end
    end

    context "by custom permalink" do
      # Support for legacy URLs
      it "fetches an oldest product if not scoped to a specific user" do
        expect(Link.fetch_leniently("custom")).to eq(product_2)
      end

      it "fetches a product for the correct user" do
        expect(Link.fetch_leniently("custom", user: user_2)).to eq(product_6)
      end

      it "scopes search to specific user if provided" do
        expect(Link.fetch_leniently("awesome", user: user_2)).to eq(product_5)
        expect(Link.fetch_leniently("awesome", user: user_1)).to eq(nil)
      end

      it "does not fetch a deleted product" do
        expect(Link.fetch_leniently("no-longer-alive")).to eq(nil)
      end
    end

    describe "legacy permalink mapping" do
      context "when no mapping exists" do
        it "fetches the oldest product if no user is provided" do
          expect(Link.fetch_leniently("custom")).to eq(product_2)
        end

        it "fetches a product for the correct user if one is provided" do
          expect(Link.fetch_leniently("custom", user: user_2)).to eq(product_6)
        end
      end

      context "when legacy permalink mapping exists" do
        before do
          create(:legacy_permalink, permalink: "custom", product: product_6)
        end

        it "fetches a mapped product when no user provided" do
          expect(Link.fetch_leniently("custom")).to eq(product_6)
        end

        it "does not fetch a deleted product" do
          product_6.mark_deleted!
          expect(Link.fetch_leniently("custom")).to eq(product_2)
        end

        it "fetches a user's product when user is provided" do
          expect(Link.fetch_leniently("custom", user: user_1)).to eq(product_2)
        end
      end
    end
  end

  describe "#fetch" do
    let!(:user_1) { create(:user) }
    let!(:product_1) { create(:product, user: user_1, unique_permalink: "aaa") }
    let!(:product_2) { create(:product, user: user_1, unique_permalink: "bbb", custom_permalink: "custom") }
    let!(:product_3) { create(:product, user: user_1, unique_permalink: "ccc", custom_permalink: "no-longer-alive", deleted_at: Time.current) }

    let!(:user_2) { create(:user) }
    let!(:product_4) { create(:product, user: user_2, unique_permalink: "ddd", custom_permalink: "custom") }

    it "fetches a product by unique permalink" do
      expect(Link.fetch("aaa")).to eq(product_1)
    end

    it "does not fetch a product by custom permalink" do
      expect(Link.fetch("custom")).to eq(nil)
    end

    it "scopes search to specific user if provided" do
      expect(Link.fetch("aaa", user: user_1)).to eq(product_1)
      expect(Link.fetch("aaa", user: user_2)).to eq(nil)
    end

    it "does not fetch a deleted product" do
      expect(Link.fetch("ccc")).to be_nil
    end
  end

  describe "#matches_permalink?" do
    let(:product) { build(:product, unique_permalink: "aB1", custom_permalink: "custom") }

    it "returns false on no match" do
      expect(product.matches_permalink?("invalid")).to be(false)
    end

    it "returns true on exact match via unique permalink" do
      expect(product.matches_permalink?("aB1")).to be(true)
    end

    it "returns true on case-insensitive match via unique permalink" do
      expect(product.matches_permalink?("ab1")).to be(true)
    end

    it "returns false on partial match via unique permalink" do
      expect(product.matches_permalink?("aB")).to be(false)
    end

    it "returns true on exact match via custom permalink" do
      expect(product.matches_permalink?("custom")).to be(true)
    end

    it "returns true on case-insensitive match via unique permalink" do
      expect(product.matches_permalink?("CUSTOM")).to be(true)
    end

    it "returns false on partial match via unique permalink" do
      expect(product.matches_permalink?("custo")).to be(false)
    end

    context "when custom permalink is blank" do
      let(:product) { build(:product) }

      it "returns false if empty permalink is passed" do
        expect(product.matches_permalink?(nil)).to be(false)
        expect(product.matches_permalink?("")).to be(false)
      end
    end
  end

  describe "name" do
    it "is invalid if super long" do
      expect(build(:product, name: "hi there" * 255).valid?).to be(false)
    end
  end

  describe "#checkout_custom_fields" do
    let(:product) { create(:product) }
    let!(:custom_field) { create(:custom_field, name: "Custom field", products: [product]) }
    let!(:post_purchase_custom_field) { create(:custom_field, name: "Post-purchase custom field", products: [product], is_post_purchase: true) }
    let!(:global_custom_field) { create(:custom_field, name: "Global custom field", global: true, seller: product.user) }
    let!(:post_purchase_global_custom_field) { create(:custom_field, name: "Post-purchase global custom field", seller: product.user, is_post_purchase: true, global: true) }

    it "returns all non-post-purchase custom fields" do
      expect(product.checkout_custom_fields).to eq([global_custom_field, custom_field])
    end
  end

  describe "#custom_field_descriptors" do
    let(:product) { create(:product) }

    it "returns formatted custom fields" do
      product.custom_fields << create(:custom_field, name: "I'm custom!")
      expect(product.custom_field_descriptors).to eq [
        { id: product.custom_fields.last.external_id, type: "text", name: "I'm custom!", required: false, collect_per_product: false },
      ]
    end
  end

  describe "#save_custom_view_content_button_text" do
    it "saves successfully" do
      link.save_custom_view_content_button_text("Custom Name")
      expect(link.custom_view_content_button_text).to eq "Custom Name"
    end

    it "errors if text is longer than 26 characters" do
      product = create(:product)
      text = "This text is over 26 characters and it can't be saved."
      product.save_custom_view_content_button_text(text)
      expect do
        product.save!
      end.to raise_error(ActiveRecord::RecordInvalid)
      expect(product.errors.full_messages.to_sentence).to eq("Button: #{text.length - 26} characters over limit (max: 26)")
    end
  end

  describe "#content_cannot_contain_adult_keywords" do
    let(:product) { create(:product) }

    context "content is safe" do
      it "does not add errors to the product" do
        product.name = "Safe name"
        product.description = "This is a safe description."
        product.save
        expect(product.errors).to be_empty
      end
    end

    context "description contains adult keywords" do
      it "adds an error to the product" do
        product.description = "fetish"
        product.save
        expect(product.errors.full_messages).to include("Adult keywords are not allowed")
      end
    end

    context "name contains adult keywords" do
      it "adds an error to the product" do
        product.name = "fetish"
        product.save
        expect(product.errors.full_messages).to include("Adult keywords are not allowed")
      end
    end
  end

  describe "#bundle_is_not_in_bundle" do
    let!(:product) { create(:product, :unpublished) }

    context "product is not in bundle" do
      it "does not add an error to the product" do
        product.is_bundle = true
        product.save
        expect(product.errors).to be_empty
      end
    end

    context "product is in bundle" do
      before do
        bundle = create(:product, user: product.user, is_bundle: true)
        create(:bundle_product, product:, bundle:)
      end

      it "adds an error to the product" do
        product.is_bundle = true
        product.save
        expect(product.errors.full_messages).to eq(["This product cannot be converted to a bundle because it is already part of a bundle."])
      end
    end

    context "product was in bundle" do
      before do
        bundle = create(:product, user: product.user, is_bundle: true)
        create(:bundle_product, product:, bundle:, deleted_at: Time.current)
      end

      it "does not add an error to the product" do
        product.is_bundle = true
        product.save
        expect(product.errors).to be_empty
      end
    end
  end

  describe "multifile_aware_product_file_info" do
    before do
      @multifile_enabled_product_with_one_file = create(:product, size: 200)
      @multifile_enabled_product_with_one_file.product_files << create(:product_file, link: @multifile_enabled_product_with_one_file, size: 300, pagelength: 7)

      @multifile_enabled_product_with_two_files = create(:product, size: 400)
      @multifile_enabled_product_with_two_files.product_files << create(:product_file, link: @multifile_enabled_product_with_two_files, size: 500, pagelength: 1)
      @multifile_enabled_product_with_two_files.product_files << create(:product_file, link: @multifile_enabled_product_with_two_files, size: 600, pagelength: 2)
    end

    it "returns the right file info for each type of product" do
      expect(@multifile_enabled_product_with_one_file.multifile_aware_product_file_info).to eq(Size: "300 Bytes", Length: "7 pages")
      expect(@multifile_enabled_product_with_two_files.multifile_aware_product_file_info).to eq({})
    end
  end

  describe "removed_file_info_attributes" do
    it "sets removed_file_info_attributes correctly" do
      link = build(:product)
      expect(link.removed_file_info_attributes).to eq []
      link.add_removed_file_info_attributes([:Size])
      expect(link.removed_file_info_attributes).to eq [:Size]
      link.add_removed_file_info_attributes([:Length])
      expect(link.removed_file_info_attributes).to eq %i[Size Length]
    end
  end

  context "when attributes have S3 URLs" do
    before do
      stub_const("CDN_URL_MAP", { "https://s3.amazonaws.com/gumroad/" => "https://static-2.gumroad.com/res/gumroad/" })

      @product = create(:product)
    end

    describe "#description" do
      it "replaces S3 URLs with CDN Proxy URLs" do
        original_description = %{
          <p class="">Sample description 1234</p><p class=""><br></p>
          <div class="medium-insert-images medium-insert-active contains-image-2085007717">
            <figure contenteditable="false">
              <img src="https://s3.amazonaws.com/gumroad/files/sample/sample/original/sample.jpg" alt="">
            </figure>
          </div>
        }

        updated_description = %{
          <p class="">Sample description 1234</p><p class=""><br></p>
          <div class="medium-insert-images medium-insert-active contains-image-2085007717">
            <figure contenteditable="false">
              <img src="https://static-2.gumroad.com/res/gumroad/files/sample/sample/original/sample.jpg" alt="">
            </figure>
          </div>
        }

        @product.update(description: original_description)

        expect(@product.description).to eq updated_description
      end
    end
  end

  describe "description formatting" do
    before do
      @product = create(:product)
    end

    it "removes xml tags from the description field if there are any" do
      desc = "<!--?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?-->\r\n\r\nBy purchasing, you are granted a "
      desc += "full, exclusive license to this track. This is one-of-a-kind and royalty-free. Visit our website for full licensing info.<br>"
      @product.description = desc
      @product.save!
      e_desc = "\r\n\r\nBy purchasing, you are granted a full, exclusive license to this track. This is "
      e_desc += "one-of-a-kind and royalty-free. Visit our website for full licensing info.<br>"
      expect(@product.description).to eq e_desc

      desc = "We all have files, pictures or notes on our computer that we'd like to protect. This step-by-step guide "
      desc += "will show you how to securely encrypt any file or files on your Mac for FREE. <div><br></div><div>You'll learn how to use all of your Mac's "
      desc += "built in tools to secure ANY file with military-grade protection. </div><div><br></div><div><!--?xml version=\"1.0\" encoding=\"UTF-8\" "
      desc += "standalone=\"no\"?-->\r\n\r\nNo technical expertise is required. File is delivered as a secure PDF.<br></div>"
      @product.description = desc
      @product.save!
      e_desc = "We all have files, pictures or notes on our computer that we'd like to protect. This step-by-step guide "
      e_desc += "will show you how to securely encrypt any file or files on your Mac for FREE. <div><br></div>"
      e_desc += "<div>You'll learn how to use all of your Mac's built in tools to secure ANY file with military-grade protection. "
      e_desc += "</div><div><br></div><div>\r\n\r\nNo technical expertise is required. File is delivered "
      e_desc += "as a secure PDF.<br></div>"
      expect(@product.description).to eq e_desc

      desc = "(<!--[if gte mso 9]><xml>\n <w:WordDocument>\n  <w:View>Normal</w:View>\n  <w:Zoom>0</w:Zoom>\n "
      desc += "<w:DoNotOptimizeForBrowser></w:DoNotOptimizeForBrowser>\n </w:WordDocument>\n</xml><![endif]--><span style=\"font-size:14.0pt;"
      desc += "mso-bidi-font-size:12.0pt;\nfont-family:\" times=\"\" new=\"\" roman\";mso-fareast-font-family:\"times=\"\" roman\";=\"\" "
      desc += "mso-ansi-language:en-us;mso-fareast-language:en-us;mso-bidi-language:ar-sa\"=\"\">93.8\nmi - 2 hr 49 min)&nbsp;</span> test <br><br>"
      @product.description = desc
      @product.save!
      e_desc = "(<span style=\"font-size:14.0pt;mso-bidi-font-size:12.0pt;\nfont-family:\" times=\"\" new=\"\" "
      e_desc += "roman\";mso-fareast-font-family:\"times=\"\" roman\";=\"\" mso-ansi-language:en-us;mso-fareast-language:en-us;mso-bidi-language:ar-sa\"=\"\">"
      e_desc += "93.8\nmi - 2 hr 49 min)&nbsp;</span> test <br><br>"
      expect(@product.description).to eq e_desc
    end
  end

  describe "as_json method" do
    before do
      @product = create(:product, name: "some link", require_shipping: true)
    end

    it "returns the correct has for default (public)" do
      expect(@product.as_json.key?("name")).to be(true)
      expect(@product.as_json.key?("require_shipping")).to be(true)
      expect(@product.as_json.key?("url")).to be(false)
    end

    context "for api" do
      context "[:view_public] scope" do
        it "returns the correct hash" do
          json = @product.as_json(api_scopes: ["view_public"])
          %w[
            name description require_shipping preview_url url
            max_purchase_count custom_receipt customizable_price
            custom_summary deleted custom_fields
          ].each do |key|
            expect(json.key?(key)).to be(true)
          end
        end

        it "includes pricing data for a tiered membership product" do
          product = create(:membership_product_with_preset_tiered_pricing)

          json = product.as_json(api_scopes: ["view_public"])

          expect(json["is_tiered_membership"]).to eq true
          expect(json["recurrences"]).to eq ["monthly"]
          tiers_json = json["variants"][0][:options]
          tiers_json.map do |tier_json|
            expect(tier_json[:is_pay_what_you_want]).to eq false
            expect(tier_json[:recurrence_prices].keys).to eq ["monthly"]
            expect(tier_json[:recurrence_prices]["monthly"].keys).to match_array [:price_cents, :suggested_price_cents]
          end
        end

        it "returns thumbnail_url information" do
          thumbnail = create(:thumbnail)
          product = thumbnail.product

          json = product.as_json(api_scopes: ["view_public"])
          expect(json["thumbnail_url"]).to eq thumbnail.url
        end

        it "returns tags" do
          @product.tag!("one")
          @product.tag!("two")

          json = @product.as_json(api_scopes: ["view_public"])
          expect(json["tags"]).to contain_exactly("one", "two")
        end
      end
    end

    it "returns the correct text for custom_summary" do
      @product.save_custom_summary("test")
      json = @product.as_json(api_scopes: ["view_public"])
      expect(json["custom_summary"]).to eq "test"
      @product.save_custom_summary(nil)
      json = @product.as_json(api_scopes: ["view_public"])
      expect(json["custom_summary"]).to eq nil
      @product.save_custom_summary("")
      json = @product.as_json(api_scopes: ["view_public"])
      expect(json["custom_summary"]).to eq ""
    end

    it "returns the correct values for custom_fields" do
      json = @product.as_json(api_scopes: ["view_public"])
      expect(json["custom_fields"]).to eq []

      @product.custom_fields << create(:custom_field, name: "I'm custom!")
      json = @product.as_json(api_scopes: ["view_public"])
      expect(json["custom_fields"]).to eq [
        { id: @product.custom_fields.last.external_id, type: "text", name: "I'm custom!", required: false, collect_per_product: false },
      ].as_json
    end

    it "returns the correct hash for api, :view_public,:edit_products" do
      json = @product.as_json(api_scopes: %w[view_public edit_products])
      %w[
        name description require_shipping preview_url url
        max_purchase_count custom_receipt customizable_price
        custom_summary deleted custom_fields
      ].each do |key|
        expect(json.key?(key)).to be(true)
      end
      %w[
        sales_count sales_usd_cents view_count
      ].each do |key|
        expect(json.key?(key)).to be(false)
      end
    end

    it "returns the correct value for max_purchase_count if it is not set by the user" do
      expect(@product.as_json(api_scopes: %w[view_public edit_products])["max_purchase_count"]).to be(nil)
    end

    it "returns the correct value for max_purchase_count if it is set by the user" do
      @product.update(max_purchase_count: 10)
      expect(@product.reload.as_json(api_scopes: %w[view_public edit_products])["max_purchase_count"]).to eq 10
    end

    it "returns the correct hash for api, :view_sales" do
      %w[name description require_shipping url file_info sales_count sales_usd_cents].each do |key|
        expect(@product.as_json(api_scopes: ["view_sales"]).key?(key)).to be(true)
      end
    end

    it "includes the preorder_link information for an unreleased link" do
      @product.update(is_in_preorder_state: true)
      @preorder_link = create(:preorder_link, link: @product, release_at: 2.days.from_now)
      link_json = @product.as_json
      expect(link_json["is_preorder"]).to be(true)
      expect(link_json["is_in_preorder_state"]).to be(true)
      expect(link_json["release_at"].present?).to be(true)
    end

    it "includes the preorder_link information for a released link" do
      @preorder_link = create(:preorder_link, link: @product, release_at: 2.days.from_now) # can't create a preorder with a release_at in the past
      @preorder_link.update(release_at: Date.yesterday)
      link_json = @product.as_json
      expect(link_json["is_preorder"]).to be(true)
      expect(link_json["is_in_preorder_state"]).to be(false)
      expect(link_json["release_at"].present?).to be(true)
    end

    it "includes deprecated `custom_delivery_url` attribute" do
      expect(@product.as_json).to include("custom_delivery_url" => nil)
    end

    it "includes deprecated `url` attribute" do
      expect(@product.as_json(api_scopes: %w[view_public edit_products])).to include("url" => nil)
    end

    describe "as_json_for_api" do
      context "for a product with variants" do
        let(:product) { create(:product) }
        let(:category) { create(:variant_category, link: product, title: "Color") }
        let!(:blue_variant) { create(:variant, variant_category: category, name: "Blue") }
        let!(:green_variant) { create(:variant, variant_category: category, name: "Green") }

        it "returns deprecated `url` attribute" do
          result = product.as_json(api_scopes: %w[view_public edit_products])
          expect(result.dig("variants", 0, :options)).to include(
            hash_including(name: "Blue", url: nil),
            hash_including(name: "Green", url: nil),
          )
        end
      end

      context "when user has purchasing_power_parity_enabled" do
        before do
          @product.user.update!(purchasing_power_parity_enabled: true)
          @product.update!(price_cents: 300)
          PurchasingPowerParityService.new.set_factor("MX", 0.5)
        end

        it "includes PPP prices for every country" do
          result = @product.as_json(api_scopes: %w[view_sales])
          expect(result["purchasing_power_parity_prices"].keys).to eq(Compliance::Countries.mapping.keys)
          expect(result["purchasing_power_parity_prices"]["MX"]).to eq(150)
        end

        context "when injecting a preloaded factors" do
          it "includes PPP prices for every country without calling PurchasingPowerParityService" do
            expect_any_instance_of(PurchasingPowerParityService).not_to receive(:get_all_countries_factors)
            result = @product.as_json(
              api_scopes: %w[view_sales],
              preloaded_ppp_factors: { "MX" => 0.8, "CA" => 0.9 }
            )
            expect(result["purchasing_power_parity_prices"]).to eq("MX" => 240, "CA" => 270)
          end
        end
      end

      context "when user has purchasing_power_parity_enabled and product has purchasing_power_parity_disabled" do
        before do
          @product.user.update!(purchasing_power_parity_enabled: true)
          @product.update!(price_cents: 300, purchasing_power_parity_disabled: true)
          PurchasingPowerParityService.new.set_factor("MX", 0.5)
        end

        it "doesn't include PPP prices for every country" do
          result = @product.as_json(api_scopes: %w[view_sales])
          expect(result["purchasing_power_parity_prices"]).to be_nil
        end
      end

      context "when api_scopes includes 'view_sales'", :sidekiq_inline, :elasticsearch_wait_for_refresh do
        it "includes sales data" do
          product = create(:product)
          create(:purchase, link: product)
          create(:failed_purchase, link: product)

          result = product.as_json(api_scopes: %w[view_sales])
          expect(result["sales_count"]).to eq(1)
          expect(result["sales_usd_cents"]).to eq(100)
        end
      end
    end

    describe "as_json_for_mobile_api" do
      it "returns proper json for a product" do
        link = create(:product, preview: fixture_file_upload("kFDzu.png", "image/png"), content_updated_at: Time.current)
        json_hash = link.as_json(mobile: true)
        %w[name description unique_permalink created_at updated_at content_updated_at preview_url].each do |attr|
          attr = attr.to_sym unless %w[name description unique_permalink].include?(attr)
          expect(json_hash[attr]).to eq link.send(attr)
        end
        expect(json_hash[:preview_oembed_url]).to eq ""
        expect(json_hash[:preview_height]).to eq 210
        expect(json_hash[:preview_width]).to eq 670
        expect(json_hash[:has_rich_content]).to eq true
      end

      it "returns thumbnail information" do
        thumbnail = create(:thumbnail)
        product = thumbnail.product

        json_hash = product.as_json(mobile: true)
        expect(json_hash[:thumbnail_url]).to eq thumbnail.url
      end

      it "returns creator info for a product" do
        user = create(:named_user, :with_avatar)

        product = create(:product, user:)
        json_hash = product.as_json(mobile: true)
        expect(json_hash[:creator_name]).to eq user.name_or_username
        expect(json_hash[:creator_profile_picture_url]).to eq user.avatar_url
        expect(json_hash[:creator_profile_url]).to eq user.profile_url
      end

      it "returns a blank preview_url if there is no preview for the product" do
        link = create(:product, preview: fixture_file_upload("kFDzu.png", "image/png"))
        link.asset_previews.each { |preview| preview.update(deleted_at: Time.current) }
        json_hash = link.as_json(mobile: true)
        expect(json_hash[:preview_url]).to eq ""
      end

      it "returns proper json for a product with a youtube preview" do
        link = create(:product, preview_url: "https://youtu.be/blSl487coFg")
        expect(link.as_json(mobile: true)[:preview_oembed_url]).to eq("https://www.youtube.com/embed/blSl487coFg?feature=oembed&showinfo=0&controls=0&rel=0&enablejsapi=1")
      end

      it "returns proper json for a product with a soundcloud preview" do
        link = create(:product, preview_url: "https://soundcloud.com/cade-turner/cade-turner-symphony-of-light", user: create(:user, username: "elliomax"))
        json_hash = link.as_json(mobile: true)
        %w[name description unique_permalink created_at updated_at].each do |attr|
          attr = attr.to_sym unless %w[name description unique_permalink].include?(attr)
          expect(json_hash[attr]).to eq link.send(attr)
        end
        expect(json_hash[:creator_name]).to eq "elliomax"
        expect(json_hash[:preview_url]).to eq "https://i1.sndcdn.com/artworks-000053047348-b62qv1-t500x500.jpg"
        expect(json_hash[:preview_oembed_url]).to eq(
          "https://w.soundcloud.com/player/?visual=true&url=https%3A%2F%2Fapi.soundcloud.com%2Ftracks%2F101276036&auto_play=false" \
          "&show_artwork=false&show_comments=false&buying=false&sharing=false&download=false&show_playcount=false&show_user=false&liking=false&maxwidth=670"
        )
      end

      it "returns proper json for a product with a vimeo preview" do
        link = create(:product, preview_url: "https://vimeo.com/30698649", user: create(:user, username: "elliomax"))
        json_hash = link.as_json(mobile: true)
        %w[name description unique_permalink created_at updated_at].each do |attr|
          attr = attr.to_sym unless %w[name description unique_permalink].include?(attr)
          expect(json_hash[attr]).to eq link.send(attr)
        end
        expect(json_hash[:creator_name]).to eq "elliomax"
        expect(json_hash[:preview_url]).to eq "https://i.vimeocdn.com/video/212645621_640.jpg"
        expect(json_hash[:preview_oembed_url]).to eq "https://player.vimeo.com/video/30698649?app_id=122963"
      end

      it "does not return preview heights less than 204 pixels" do
        link = create(:product, preview: fixture_file_upload("kFDzu.png", "image/png"))
        allow_any_instance_of(Link).to receive(:preview_height).and_return(100)
        json_hash = link.as_json(mobile: true)
        %w[name description unique_permalink created_at updated_at preview_url].each do |attr|
          attr = attr.to_sym unless %w[name description unique_permalink].include?(attr)
          expect(json_hash[attr]).to eq link.send(attr)
        end
        expect(json_hash[:creator_name]).to eq link.user.username
        expect(json_hash[:preview_oembed_url]).to eq ""
        expect(json_hash[:preview_height]).to eq 0
        expect(json_hash[:preview_width]).to eq 670
      end

      it "returns 'has_rich_content' true" do
        product = create(:product)

        expect(product.as_json(mobile: true)[:has_rich_content]).to eq(true)
      end
    end

    describe "as_json_variant_details_only" do
      context "for a product with variants" do
        it "includes a hash of variants data under 'categories'" do
          circle_integration = create(:circle_integration)
          discord_integration = create(:discord_integration)
          product = create(:product, active_integrations: [circle_integration, discord_integration])
          category = create(:variant_category, link: product, title: "Color")
          blue_variant = create(:variant, variant_category: category, name: "Blue", active_integrations: [circle_integration])
          green_variant = create(:variant, variant_category: category, name: "Green", active_integrations: [discord_integration])
          result = product.as_json(variant_details_only: true)

          expect(result).to eq(
            categories: {
              category.external_id => {
                title: "Color",
                options: {
                  blue_variant.external_id => {
                    "option" => blue_variant.name,
                    "name" => blue_variant.name,
                    "description" => nil,
                    "id" => blue_variant.external_id,
                    "max_purchase_count" => nil,
                    "price_difference_cents" => 0,
                    "price_difference_in_currency_units" => 0.0,
                    "showing" => false,
                    "quantity_left" => nil,
                    "amount_left_title" => "",
                    "displayable" => blue_variant.name,
                    "sold_out" => false,
                    "price_difference" => "0",
                    "currency_symbol" => "$",
                    "product_files_ids" => [],
                    "integrations" => { "circle" => true, "discord" => false, "zoom" => false, "google_calendar" => false },
                  },
                  green_variant.external_id => {
                    "option" => green_variant.name,
                    "name" => green_variant.name,
                    "description" => nil,
                    "id" => green_variant.external_id,
                    "max_purchase_count" => nil,
                    "price_difference_cents" => 0,
                    "price_difference_in_currency_units" => 0.0,
                    "showing" => false,
                    "quantity_left" => nil,
                    "amount_left_title" => "",
                    "displayable" => green_variant.name,
                    "sold_out" => false,
                    "price_difference" => "0",
                    "currency_symbol" => "$",
                    "product_files_ids" => [],
                    "integrations" => { "circle" => false, "discord" => true, "zoom" => false, "google_calendar" => false },
                  }
                }
              }
            },
            skus: {},
            skus_enabled: false
          )
        end

        it "sets category title to \"Version\" if there is no title" do
          product = create(:product)
          category = create(:variant_category, link: product, title: "")
          result = product.as_json(variant_details_only: true)

          expect(result).to eq(
            categories: {
              category.external_id => {
                title: "Version",
                options: {}
              }
            },
            skus: {},
            skus_enabled: false
          )
        end
      end

      context "for a tiered membership" do
        it "includes a hash of tier data under 'categories'" do
          circle_integration = create(:circle_integration)
          discord_integration = create(:discord_integration)
          product = create(:membership_product, name: "My Membership", active_integrations: [circle_integration, discord_integration])
          category = product.tier_category
          first_tier = category.variants.first
          first_tier.active_integrations << circle_integration
          second_tier = create(:variant, variant_category: category, name: "2nd Tier", active_integrations: [discord_integration])

          result = product.as_json(variant_details_only: true)

          expect(result).to eq(
            categories: {
              category.external_id => {
                title: "Tier",
                options: {
                  first_tier.external_id => {
                    "option" => "Untitled",
                    "name" => "My Membership",
                    "description" => nil,
                    "id" => first_tier.external_id,
                    "max_purchase_count" => nil,
                    "price_difference_cents" => nil,
                    "price_difference_in_currency_units" => 0.0,
                    "showing" => true,
                    "quantity_left" => nil,
                    "amount_left_title" => "",
                    "displayable" => "Untitled",
                    "sold_out" => false,
                    "price_difference" => 0,
                    "currency_symbol" => "$",
                    "product_files_ids" => [],
                    "is_customizable_price" => false,
                    "recurrence_price_values" => {
                      "monthly" => { enabled: true, price: "1", price_cents: 100, suggested_price_cents: nil },
                      "quarterly" => { enabled: false },
                      "biannually" => { enabled: false },
                      "yearly" => { enabled: false },
                      "every_two_years" => { enabled: false },
                    },
                    "integrations" => { "circle" => true, "discord" => false, "zoom" => false, "google_calendar" => false },
                  },
                  second_tier.external_id => {
                    "option" => second_tier.name,
                    "name" => second_tier.name,
                    "description" => nil,
                    "id" => second_tier.external_id,
                    "max_purchase_count" => nil,
                    "price_difference_cents" => 0,
                    "price_difference_in_currency_units" => 0.0,
                    "showing" => false,
                    "quantity_left" => nil,
                    "amount_left_title" => "",
                    "displayable" => second_tier.name,
                    "sold_out" => false,
                    "price_difference" => "0",
                    "currency_symbol" => "$",
                    "product_files_ids" => [],
                    "is_customizable_price" => false,
                    "recurrence_price_values" => {
                      "monthly" => { enabled: false },
                      "quarterly" => { enabled: false },
                      "biannually" => { enabled: false },
                      "yearly" => { enabled: false },
                      "every_two_years" => { enabled: false },
                    },
                    "integrations" => { "circle" => false, "discord" => true, "zoom" => false, "google_calendar" => false },
                  }
                }
              }
            },
            skus: {},
            skus_enabled: false
          )
        end
      end

      context "for a product with skus_enabled" do
        it "includes a hash of SKUs data under 'skus'" do
          product = create(:physical_product)
          category_1 = create(:variant_category, link: product, title: "Color")
          category_2 = create(:variant_category, link: product, title: "Size")
          skus_title = "#{category_1.title} - #{category_2.title}"
          sku = create(:sku, link: product, name: "Blue - large")

          result = product.as_json(variant_details_only: true)

          expect(result).to eq(
            categories: {
              category_1.external_id => {
                title: category_1.title,
                options: {}
              },
              category_2.external_id => {
                title: category_2.title,
                options: {}
              }
            },
            skus: {
              sku.external_id => {
                "option" => sku.name,
                "name" => sku.name,
                "description" => nil,
                "id" => sku.external_id,
                "max_purchase_count" => nil,
                "price_difference_cents" => 0,
                "price_difference_in_currency_units" => 0.0,
                "showing" => false,
                "quantity_left" => nil,
                "amount_left_title" => "",
                "displayable" => sku.name,
                "sold_out" => false,
                "price_difference" => "0",
                "currency_symbol" => "$",
                "product_files_ids" => [],
                "integrations" => { "circle" => false, "discord" => false, "zoom" => false, "google_calendar" => false },
              }
            },
            skus_title:,
            skus_enabled: true
          )
        end
      end

      context "for a product without variants" do
        it "returns empty objects" do
          product = create(:product)

          result = product.as_json(variant_details_only: true)

          expect(result).to eq(
            categories: {},
            skus: {},
            skus_enabled: false
          )
        end
      end
    end

    describe "recommendable attribute" do
      it "returns true if the product is recommendable" do
        product = create(:product, :recommendable)
        json = product.as_json
        expect(json["recommendable"]).to eq true
      end

      it "returns false otherwise" do
        product = create(:product)
        json = product.as_json
        expect(json["recommendable"]).to eq false
      end
    end

    describe "rated_as_adult attribute" do
      it "returns true if the product is rated_as_adult" do
        product = create(:product, is_adult: true)
        json = product.as_json
        expect(json["rated_as_adult"]).to eq true
      end

      it "returns false otherwise" do
        product = create(:product)
        json = product.as_json
        expect(json["rated_as_adult"]).to eq false
      end
    end
  end

  describe "yen" do
    before { subject.price_currency_type = :jpy }
    it "is a single-unit currency" do
      expect(subject.send(:single_unit_currency?)).to be(true)
    end
  end

  describe "#remaining_for_sale_count" do
    it "defaults to nil" do
      expect(link.max_purchase_count).to be(nil)
      expect(link.remaining_for_sale_count).to be(nil)
    end

    it "does not return nil if there's no max purchase count if there is a tier with a max purchase count" do
      link = create(:membership_product)
      link.tiers.first.update!(max_purchase_count: 100)
      expect(link.remaining_for_sale_count).to eq 100
      link.tiers.first.update!(max_purchase_count: 200)
      expect(link.remaining_for_sale_count).to eq 200
    end

    describe "less than infinity" do
      before { link.max_purchase_count = 50 }

      it "defaults to 50" do
        expect(link.remaining_for_sale_count).to eq 50
      end

      describe "purchases were made" do
        let(:purchase) { build(:purchase, link:) }
        let(:purchase_2) { build(:purchase_2, link:) }
        let(:failed_purchase) { build(:purchase_2, link:, purchase_state: "failed") }

        before do
          purchase.save!
          purchase_2.save!
          failed_purchase.save!
        end

        it "decrements the remaining count" do
          expect(link.remaining_for_sale_count).to eq 48
        end

        describe "user attempts to set remaining purchase count below the number of purchases" do
          before { link.max_purchase_count = 1 }

          it "is not valid" do
            expect(link.valid?).to be(false)
          end
        end
      end
    end

    describe "bundle product" do
      let(:bundle) { create(:product, :bundle, max_purchase_count: 3) }

      it "returns the minimum quantity remaining out of the bundle and the bundle products" do
        expect(bundle.remaining_for_sale_count).to eq(3)
        bundle.bundle_products.second.product.update!(max_purchase_count: 2)
        expect(bundle.remaining_for_sale_count).to eq(2)
        bundle_product = bundle.bundle_products.first
        bundle_product.update!(variant: create(:variant, variant_category: create(:variant_category, link: bundle_product.product), max_purchase_count: 1))
        expect(bundle.remaining_for_sale_count).to eq(1)
      end

      it "excludes deleted bundle products" do
        expect(bundle.remaining_for_sale_count).to eq(3)
        bundle.bundle_products.second.product.update!(max_purchase_count: 2)
        expect(bundle.remaining_for_sale_count).to eq(2)
        bundle.bundle_products.second.mark_deleted!
        expect(bundle.remaining_for_sale_count).to eq(3)
      end
    end
  end

  describe "#remaining_call_availabilities" do
    let(:call_product) { create(:call_product) }

    it "calls Product::ComputeCallAvailabilitiesService with self as parameter" do
      service_instance = instance_double(Product::ComputeCallAvailabilitiesService)

      expect(Product::ComputeCallAvailabilitiesService).to receive(:new).with(call_product).and_return(service_instance)
      expect(service_instance).to receive(:perform)

      call_product.remaining_call_availabilities
    end
  end

  describe "plaintext description" do
    it "keeps a normal description the same" do
      link = create(:product, description: "I like pie.")
      expect(link.plaintext_description).to eq "I like pie."
    end

    it "properly cleans a html description" do
      link = create(:product, description: "I like <strong><u>pie</u></strong>. Do you?")
      expect(link.plaintext_description).to eq "I like pie. Do you?"
    end

    it "encodes lone `<`, `>` characters" do
      link = create(:product, description: "some < text >")
      expect(link.plaintext_description).to eq "some &lt; text &gt;"
    end

    it "does not encode `'`" do
      link = create(:product, description: "The world's foremost")
      expect(link.plaintext_description).to eq "The world's foremost"
    end
  end

  describe "default_price_recurrence" do
    it "returns the product price that has the product's subscription duration" do
      product = create(:membership_product, subscription_duration: BasePrice::Recurrence::MONTHLY)
      monthly_price = product.prices.find_by!(recurrence: BasePrice::Recurrence::MONTHLY)
      yearly_price = create(:price, link: product, recurrence: BasePrice::Recurrence::YEARLY)
      create(:price, link: product, recurrence: BasePrice::Recurrence::QUARTERLY)

      product.reload

      expect(product.default_price_recurrence).to eq monthly_price

      product.update!(subscription_duration: BasePrice::Recurrence::YEARLY)

      expect(product.reload.default_price_recurrence).to eq yearly_price
    end

    context "for a product without recurring billing" do
      it "returns nil" do
        product = create(:product)
        create(:price, link: product)

        expect(product.default_price_recurrence).to be_nil
      end
    end
  end

  describe "default_price" do
    context "for a non-recurring billing product" do
      it "returns the last price" do
        product = create(:product)
        create(:price, link: product, price_cents: 100)
        last_price = create(:price, link: product, price_cents: 200)

        product.reload

        expect(product.default_price).to eq last_price
      end
    end

    context "for a recurring billing product that is not a tiered membership" do
      it "returns the price with the correct recurrence" do
        product = create(:subscription_product, subscription_duration: BasePrice::Recurrence::MONTHLY)
        monthly_price = create(:price, link: product, recurrence: BasePrice::Recurrence::MONTHLY)
        create(:price, link: product, recurrence: BasePrice::Recurrence::YEARLY)

        product.reload

        expect(product.default_price).to eq monthly_price
      end
    end

    context "for a tiered membership product" do
      it "returns the product price with the correct recurrence" do
        recurrence_price_values = [
          {
            BasePrice::Recurrence::MONTHLY => { enabled: true, price: 2 },
            BasePrice::Recurrence::YEARLY => { enabled: true, price: 2 }
          },
          {
            BasePrice::Recurrence::MONTHLY => { enabled: true, price: 2 },
            BasePrice::Recurrence::YEARLY => { enabled: true, price: 2 }
          }
        ]
        product = create(:membership_product_with_preset_tiered_pricing, subscription_duration: BasePrice::Recurrence::YEARLY, recurrence_price_values:)
        yearly_price = product.prices.alive.find_by!(recurrence: BasePrice::Recurrence::YEARLY)

        expect(product.default_price).to eq yearly_price
      end
    end
  end

  describe "suggested_price_cents" do
    it "suggested_price should set suggested_price_cents" do
      link = create(:product)
      link.suggested_price = 4
      expect(link.suggested_price_cents).to eq 400

      link.suggested_price = nil
      expect(link.suggested_price_cents).to be_nil
    end

    it "suggested_price_formatted should be correct" do
      link = create(:product, suggested_price_cents: 400)
      expect(link.suggested_price_formatted).to eq "4"
    end

    it "suggested_price_cents cannot be less than price cents" do
      link = create(:product)
      link.price_range = "2+"
      link.suggested_price_cents = 100
      expect(link.valid?).to be(false)
    end

    describe "non-customizable price" do
      it "does not validate suggested price" do
        link = create(:product, price_cents: 200)
        link.suggested_price_cents = 100
        expect(link.valid?).to be(true)
      end
    end
  end

  describe "#price_range" do
    it "can be assigned a number" do
      link.price_range = 1
      expect(link.price_cents).to eq 100

      link.price_range = 1.01
      expect(link.price_cents).to eq 101

      link.price_range = 10.01
      expect(link.price_cents).to eq 1001
    end

    it "absorbs random data" do
      link.price_range = "1sdlkjglsjdhgfsjhdgf"
      expect(link.price_cents).to eq 100

      link.price_range = "1.sdlkjglsjdhgfsjhdgf01"
      expect(link.price_cents).to eq 101

      link.price_range = "1sdlkjglsjdhgfsjhdgf0.01"
      expect(link.price_cents).to eq 1001
    end

    it "treats a tailing plus sign as customizable" do
      link.price_range = "0.99+"
      expect(link.customizable_price).to be(true)

      link.price_range = "0.99"
      expect(link.customizable_price).to be(false)
    end

    describe "american dollar" do
      before { link.price_currency_type = :usd }

      it "sets price cents" do
        link.price_range = "1"
        expect(link.price_cents).to eq 100

        link.price_range = "1.01"
        expect(link.price_cents).to eq 101

        link.price_range = "10.01"
        expect(link.price_cents).to eq 1001
      end
    end

    describe "english pound" do
      before { link.price_currency_type = :gbp }

      it "sets price cents" do
        link.price_range = "1"
        expect(link.price_cents).to eq 100

        link.price_range = "1.01"
        expect(link.price_cents).to eq 101

        link.price_range = "10.01"
        expect(link.price_cents).to eq 1001
      end

      it "saves price cents correctly too" do
        link.price_range = "10.01"
        link.save!
        expect(link.price_cents).to eq 1001
      end
    end

    describe "japanese yen" do
      before do
        link.price_currency_type = "jpy"
        link.price_range = "100"
      end

      it "costs 100 ¥" do
        expect(link.price_cents).to eq 100
      end

      it "sets price cents correctly for yen if they try to do point values" do
        link.price_range = "¥100.01"
        expect(link.price_cents).to eq 100
      end

      it "saves price cents correctly" do
        link.save!
        expect(link.price_cents).to eq 100
      end

      it "saves price cents from price range if the yen symbol is not included" do
        link.price_range = "100"
        expect(link.price_cents).to eq 100
        link.save!
        expect(link.price_cents).to eq 100
      end
    end

    describe "zero+" do
      it "is valid with 0+ price_range" do
        link.price_range = "0+"
        expect(link.save).to be(true)
      end

      it "is invalid with 0.5+ price_range" do
        link.price_range = "0.50+"
        expect(link.save).to be(false)
      end

      it "is valid with 1+ price_range" do
        link.price_range = "1+"
        expect(link.save).to be(true)
      end
    end

    describe "euro style" do
      it "handles euro-style entries" do
        link.user.update!(verified: true)
        link.price_range = "999,99"
        link.save!
        expect(link.price_cents).to eq 99_999
        link.price_range = "999.99"
        link.save!
        expect(link.price_cents).to eq 99_999
        link.price_range = "1.999,99"
        link.save!
        expect(link.price_cents).to eq 199_999
        link.price_range = "1,999.99"
        link.save!
        expect(link.price_cents).to eq 199_999
        link.price_range = "1,999"
        link.save!
        expect(link.price_cents).to eq 199_900
      end
    end
  end

  describe "#rental_price_range" do
    it "treats a tailing plus sign in rental price as customizable price only if product is rent-only" do
      link.purchase_type = :rent_only
      link.rental_price_cents = 100
      link.save!
      link.rental_price_range = "1.99+"
      expect(link.customizable_price).to be(true)
      expect(link.price_cents).to eq(199)

      link.rental_price_range = "0.99"
      expect(link.customizable_price).to be(false)
      expect(link.price_cents).to eq(99)

      link.purchase_type = :buy_only
      link.price_cents = 100
      link.save!
      link.rental_price_range = "1.99+"
      expect(link.customizable_price).to be(false)
      expect(link.price_cents).to eq(100)

      link.purchase_type = :buy_and_rent
      link.save!
      link.rental_price_range = "1.99+"
      expect(link.customizable_price).to be(false)
      expect(link.price_cents).to eq(100)
      expect(link.rental_price_cents).to eq(199)
    end
  end

  it "creates a permalink" do
    link.save!
    expect(link.unique_permalink).to_not be(nil)
  end

  describe "#price_formatted" do
    before(:each) { @product = create(:product) }
    describe "usd price formatted standard" do
      before(:each) { @product.price_range = "1.00" }

      it "is $1.00" do
        expect(@product.price_cents).to eq 100
        expect(@product.price_formatted).to eq "$1"
        expect(@product.price_formatted_without_dollar_sign).to eq "1"
      end
    end

    describe "usd price formatted non-standard" do
      before(:each) do
        @product.price_range = "1.01"
        @product.save!
      end

      it "is $1.01" do
        expect(@product.price_cents).to eq 101
        expect(@product.price_formatted).to eq "$1.01"
        expect(@product.price_formatted_without_dollar_sign).to eq "1.01"
      end
    end

    describe "usd price formatted with customizable price" do
      before(:each) do
        @product.price_range = "2.5+"
        @product.save!
      end

      it "is $2.50" do
        expect(@product.price_cents).to eq 250
        expect(@product.price_formatted).to eq "$2.50"
        expect(@product.price_formatted_without_dollar_sign).to eq "2.50"
      end
    end

    describe "jpy price formatted standard" do
      before(:each) do
        @product.update(price_currency_type: :jpy, price_range: "100")
      end

      it "is ¥100" do
        expect(@product.price_cents).to eq 100
        expect(@product.price_formatted).to eq "¥100"
        expect(@product.price_formatted_without_dollar_sign).to eq "100"
      end
    end

    describe "jpy price formatted non-standard" do
      before(:each) do
        @product.update(price_currency_type: :jpy, price_range: "104")
      end

      it "is ¥104" do
        expect(@product.price_cents).to eq 104
        expect(@product.price_formatted).to eq "¥104"
        expect(@product.price_formatted_without_dollar_sign).to eq "104"
      end
    end

    describe "jpy price formmated with customizable price" do
      before(:each) do
        @product.update(price_currency_type: :jpy, price_range: "177+")
      end

      it "is ¥177" do
        expect(@product.price_cents).to eq 177
        expect(@product.price_formatted).to eq "¥177"
        expect(@product.price_formatted_without_dollar_sign).to eq "177"
      end
    end
  end

  describe "total_usd_cents_earned_by_user", :sidekiq_inline, :elasticsearch_wait_for_refresh do
    it "sums up earnings for the given user" do
      user = create(:user)

      # owned product
      product = create(:product, user:)
      create(:purchase, seller: user, link: product, price_cents: 100)
      affiliate_purchase = create(:purchase, link: product, seller: user, price_cents: 200)
      create(:affiliate_credit, purchase: affiliate_purchase)
      affiliated_purchase_with_fee_splitting = create(:purchase, link: product, seller: user, price_cents: 300)
      create(:affiliate_credit, purchase: affiliated_purchase_with_fee_splitting, amount_cents: 75, fee_cents: 12)

      # affiliated product
      affiliated_product = create(:product)
      affiliated_purchase_1 = create(:purchase, link: affiliated_product, price_cents: 400)
      create(:affiliate_credit, purchase: affiliated_purchase_1, affiliate_user: user, amount_cents: 150)
      affiliated_purchase_2 = create(:purchase, link: affiliated_product, price_cents: 500)
      create(:affiliate_credit, purchase: affiliated_purchase_2, affiliate_user: user, amount_cents: 225)
      affiliated_purchase_with_fee_splitting = create(:purchase, link: affiliated_product, price_cents: 700)
      create(:affiliate_credit, purchase: affiliated_purchase_with_fee_splitting, affiliate_user: user, amount_cents: 305, fee_cents: 45)

      # sales for affiliated product by other affiliates (should not count towards total)
      affiliated_purchase_3 = create(:purchase, link: affiliated_product, price_cents: 600)
      create(:affiliate_credit, purchase: affiliated_purchase_3, affiliate_user: create(:user), amount_cents: 300)

      expect(product.total_usd_cents_earned_by_user(user)).to eq(513.0)
      expect(affiliated_product.total_usd_cents_earned_by_user(user)).to eq(725.0)
      expect(product.total_usd_cents_earned_by_user(create(:user))).to eq(0.0)
    end
  end

  describe "compliance_blocked" do
    it "is false if a good ip" do
      ip = "199.21.86.138" # San Francisco WebPass
      expect(build(:product).compliance_blocked(ip)).to be(false)
    end

    it "blocks ips from 'bad' countries, like Libya" do
      ip = "41.208.70.70" # Tripoly Libya Telecom
      expect(build(:product).compliance_blocked(ip)).to be(true)
    end

    it "does not block ips when we do not know the ip" do
      ip = nil
      expect(build(:product).compliance_blocked(ip)).to be(false)
    end

    it "does not block ips when we cannot identify the country" do
      ip = "10.0.1.1"
      expect(build(:product).compliance_blocked(ip)).to be(false)
    end
  end

  describe "#long_url" do
    before :each do
      @product = create(:product)
    end

    it "returns long_url of the product with seller's subdomain" do
      expect(@product.long_url).to eq "#{@product.user.subdomain_with_protocol}/l/#{@product.general_permalink}"
    end

    it "appends the 'recommended_by' query parameter if one is present" do
      expect(@product.long_url(recommended_by: "abc")).to eq "#{@product.user.subdomain_with_protocol}/l/#{@product.general_permalink}?recommended_by=abc"
    end

    it "does not append the 'recommended_by' query parameter if the value is blank" do
      expect(@product.long_url(recommended_by: "")).to eq "#{@product.user.subdomain_with_protocol}/l/#{@product.general_permalink}"
      expect(@product.long_url(recommended_by: " ")).to eq "#{@product.user.subdomain_with_protocol}/l/#{@product.general_permalink}"
      expect(@product.long_url(recommended_by: nil)).to eq "#{@product.user.subdomain_with_protocol}/l/#{@product.general_permalink}"
    end

    it "doesn't include protocol if include_protocol is set to false" do
      expect(@product.long_url(include_protocol: false)).to eq "#{@product.user.subdomain}/l/#{@product.general_permalink}"
    end
  end

  describe "#thumbnail_or_cover_url" do
    let(:product) { create(:product) }

    it "returns nil when the product has no thumbnail or covers" do
      expect(product.thumbnail_or_cover_url).to be_nil
    end

    it "returns the thumbnail or falls back to the first cover image" do
      thumbnail = create(:thumbnail, product:)
      expect(product.thumbnail_or_cover_url).to eq(thumbnail.url)

      create(:asset_preview_mov, link: product)
      cover = create(:asset_preview, link: product)
      expect(product.reload.thumbnail_or_cover_url).to eq(thumbnail.url)

      thumbnail.mark_deleted!
      expect(product.reload.thumbnail_or_cover_url).to eq(cover.url)
    end
  end

  describe "#for_email_thumbnail_url" do
    let(:product) { create(:product) }

    context "when the product doesn't have a thumbnail" do
      it "returns product type thumbnail" do
        expect(product.for_email_thumbnail_url).to eq(
          ActionController::Base.helpers.asset_url("native_types/thumbnails/digital.png")
        )
      end
    end

    context "when the product has an active thumbnail" do
      before do
        thumbnail = Thumbnail.new(product:)
        blob = ActiveStorage::Blob.create_and_upload!(io: fixture_file_upload("smilie.png"), filename: "smilie.png")
        blob.analyze
        thumbnail.file.attach(blob)
        thumbnail.save!
      end

      it "returns thumbnail url" do
        expect(product.for_email_thumbnail_url).to eq(product.thumbnail.alive.url)
      end

      context "when the thumbnail is deleted" do
        before do
          product.thumbnail.mark_deleted!
        end

        it "returns product type thumbnail" do
          expect(product.for_email_thumbnail_url).to eq(
            ActionController::Base.helpers.asset_url("native_types/thumbnails/digital.png")
          )
        end
      end
    end
  end

  describe "#release_custom_permalink_if_possible" do
    before do
      @user = create(:user)
      @active_product = create(:product, user: @user, custom_permalink: "seo")
      @deleted_product = create(:product, user: @user, deleted_at: Time.current, custom_permalink: "twitter")

      @another_users_deleted_product = create(:product, user: create(:user), deleted_at: Time.current, custom_permalink: "wealth")
    end

    it "releases the custom permalink of the user's deleted product" do
      new_product = build(:product, user: @user, custom_permalink: "twitter")

      expect(new_product.save).to eq(true)
      expect(@deleted_product.reload.custom_permalink).to be_nil
    end

    it "does not release the custom permalink of a non-deleted product" do
      new_product = build(:product, user: @user, custom_permalink: "seo")

      expect(new_product.save).to eq(false)
      expect(@active_product.reload.custom_permalink).to eq("seo")
    end

    it "does not release the custom permalink of another user's deleted product" do
      new_product = build(:product, user: @user, custom_permalink: "wealth")

      expect(new_product.save).to eq(true)
      expect(@another_users_deleted_product.reload.custom_permalink).to eq("wealth")
    end
  end

  describe "#has_stampable_pdfs?" do
    before do
      @product = create(:product)
    end

    it "returns false if product has no product files" do
      expect(@product.has_stampable_pdfs?).to eq(false)
    end

    it "returns false if product has no stampable pdf files" do
      @product.product_files << create(:non_readable_document)
      @product.product_files << create(:readable_document, pdf_stamp_enabled: false)

      expect(@product.has_stampable_pdfs?).to eq(false)
    end

    it "returns true if product has at least one stampable pdf file" do
      @product.product_files << create(:non_readable_document)
      @product.product_files << create(:readable_document, pdf_stamp_enabled: true)

      expect(@product.has_stampable_pdfs?).to eq(true)
    end
  end

  describe "#customize_file_per_purchase?" do
    before do
      @product = create(:product)
    end

    it "returns false if product has no product files" do
      expect(@product.customize_file_per_purchase?).to eq(false)
    end

    it "returns false if product has no stampable pdf files" do
      @product.product_files << create(:non_readable_document)
      @product.product_files << create(:readable_document, pdf_stamp_enabled: false)

      expect(@product.customize_file_per_purchase?).to eq(false)
    end

    it "returns true if product has at least one stampable pdf file" do
      @product.product_files << create(:non_readable_document)
      @product.product_files << create(:readable_document, pdf_stamp_enabled: true)

      expect(@product.customize_file_per_purchase?).to eq(true)
    end
  end

  describe "#allow_parallel_purchases?" do
    it "returns false if the product is a call" do
      expect(create(:call_product).allow_parallel_purchases?).to eq(false)
    end

    it "returns false if the product has a max purchase count" do
      product = create(:product, max_purchase_count: 1)
      expect(product.allow_parallel_purchases?).to eq(false)

      product.update!(max_purchase_count: nil)
      expect(product.allow_parallel_purchases?).to eq(true)
    end
  end

  describe "#is_downloadable?" do
    before do
      @product = create(:product)
    end

    it "returns false if product has no product files" do
      expect(@product.is_downloadable?).to eq(false)
    end

    it "returns false if product has at least one stampable pdf file" do
      @product.product_files << create(:non_readable_document)
      @product.product_files << create(:readable_document, pdf_stamp_enabled: true)

      expect(@product.is_downloadable?).to eq(false)
    end

    it "returns false if product is rent-only" do
      @product.update!(purchase_type: "rent_only", rental_price_cents: 1_00)
      @product.product_files << create(:non_readable_document)
      @product.product_files << create(:readable_document, pdf_stamp_enabled: false)

      expect(@product.is_downloadable?).to eq(false)
    end

    it "returns false if product has files that are all marked stream-only" do
      @product.product_files << create(:streamable_video, stream_only: true)
      @product.product_files << create(:streamable_video, stream_only: true)

      expect(@product.is_downloadable?).to eq(false)
    end

    it "returns true if product has unstampable files that are not marked stream-only" do
      @product.product_files << create(:non_readable_document)
      @product.product_files << create(:streamable_video, stream_only: true)
      @product.product_files << create(:readable_document, pdf_stamp_enabled: false)

      expect(@product.is_downloadable?).to eq(true)
    end
  end

  describe "#create_licenses_for_existing_customers" do
    it "queues the CreateLicensesForExistingCustomersWorker job once when licensing is enabled" do
      product = create(:product_with_pdf_file)
      product.is_licensed = true
      product.save!

      expect(CreateLicensesForExistingCustomersWorker).to have_enqueued_sidekiq_job(product.id)
    end

    it "does not queue the CreateLicensesForExistingCustomersWorker job when licensing is disabled" do
      product = create(:product_with_pdf_file, is_licensed: true)
      product.is_licensed = false
      product.save!

      expect(CreateLicensesForExistingCustomersWorker).not_to have_enqueued_sidekiq_job(product.id)
    end

    it "does not queue the CreateLicensesForExistingCustomersWorker job when a non-licensing attribute is updated" do
      product = create(:product_with_pdf_file)
      product.update!(description: "This is a new description.")

      expect(CreateLicensesForExistingCustomersWorker.jobs.size).to eq(0)
    end
  end

  describe "subscription_duration" do
    let(:link) { create(:product, subscription_duration: :monthly) }

    it "persists integer correctly" do
      link.update!(subscription_duration: :yearly)

      expect(link.reload.subscription_duration).to eq "yearly"
      expect(link.subscription_duration_before_type_cast).to eq 1
    end
  end

  describe "preorders" do
    it "allows a product to be created if it's for a preorder" do
      product = create(:product, is_in_preorder_state: true)
      expect(product.valid?).to be(true)
    end
  end



  describe "offer_code creation" do
    before :each do
      @product_for_code = create(:product, price_currency_type: "eur", price_cents: 240)
    end

    it "can create an offer code that lowers the price to 0" do
      offer_code = build(:offer_code, products: [@product_for_code], currency_type: "eur", amount_cents: 240)
      expect do
        offer_code.save!
      end.to change { OfferCode.count }.by(1)
    end

    it "can create an offer code that keeps the price above the minimum" do
      offer_code = build(:offer_code, products: [@product_for_code], currency_type: "eur", amount_cents: 100)
      expect do
        offer_code.save!
      end.to change { OfferCode.count }.by(1)
    end

    it "cannot create an offer code that brings the price to below the minimum" do
      offer_code = build(:offer_code, products: [@product_for_code], currency_type: "eur", amount_cents: 239)
      expect do
        expect do
          offer_code.save!
        end.to_not change { OfferCode.count }
      end.to raise_error(ActiveRecord::RecordInvalid)
      expect(offer_code.errors.full_messages.to_sentence).to eq "The price after discount for all of your products must be either €0 or at least €0.79."
    end
  end

  describe "#delete!" do
    it "marks custom domain as deleted" do
      product = create(:product)
      custom_domain = create(:custom_domain, domain: "www.example1.com", user: nil, product:)

      product.delete!

      expect(custom_domain.reload.alive?).to be(false)
    end

    it "enqueues subscription cancellations" do
      product = create(:product, is_recurring_billing: true, subscription_duration: "monthly")
      subscription = create(:subscription)
      product.subscriptions << subscription
      create(:purchase, subscription:, link: product, is_original_subscription_purchase: true)
      travel_to(Time.current) do
        product.delete!
        expect(CancelSubscriptionsForProductWorker).to have_enqueued_sidekiq_job(product.id).in(10.minutes)
      end
    end

    it "enqueues rich content deletions" do
      product = create(:product)

      product.delete!
      expect(DeleteProductRichContentWorker).to have_enqueued_sidekiq_job(product.id).in(10.minutes)
    end

    it "deletes all product files and archives if there are no successful sales" do
      link = create(:product)
      link.product_files << create(:product_file, link:)
      link.product_files << create(:product_file, link:, is_linked_to_existing_file: true)
      create(:purchase, link:, purchase_state: "successful")
      expect(link.reload.deleted_at).to be(nil)
      expect(link.product_files.alive.size).to eq(2)

      travel_to(Time.current) do
        link.delete!
        expect(DeleteProductFilesWorker).to have_enqueued_sidekiq_job(link.id).in(10.minutes)
        expect(DeleteProductFilesArchivesWorker).to have_enqueued_sidekiq_job(link.id, nil).in(10.minutes)
        expect(link.reload.deleted_at).not_to be(nil)
      end
    end

    it "enqueues wishlist product deletions" do
      product = create(:product)
      product.delete!
      expect(DeleteWishlistProductsJob).to have_enqueued_sidekiq_job(product.id).in(10.minutes)
    end

    it "schedules associated public files for deletion" do
      product = create(:product)
      public_file1 = create(:public_file, :with_audio, resource: product)
      public_file2 = create(:public_file, :with_audio, resource: product)
      _another_product_public_file = create(:public_file, :with_audio)

      product.delete!

      expect(public_file1.reload.file).to be_attached
      expect(public_file1).to be_alive
      expect(public_file1.scheduled_for_deletion_at).to be_within(5.seconds).of(10.minutes.from_now)
      expect(public_file2.reload.file).to be_attached
      expect(public_file2).to be_alive
      expect(public_file2.scheduled_for_deletion_at).to be_within(5.seconds).of(10.minutes.from_now)
      expect(_another_product_public_file.reload.scheduled_for_deletion_at).to be_nil
    end
  end

  describe "#ordered_by_ids" do
    it "returns a list of users' products ordered as per the input list of ids" do
      creator = create(:user)
      product1 = create(:product, user: creator)
      product2 = create(:product, user: creator, created_at: 1.minute.ago)
      product3 = create(:product, user: creator, created_at: 2.minutes.ago)
      product4 = create(:product, user: creator, created_at: 3.minutes.ago)

      product_ids = [product3.id, product1.id, product2.id, product4.id]
      expect(creator.links.ordered_by_ids(product_ids)).to eq([product3, product1, product2, product4])

      expect(creator.links.ordered_by_ids(nil)).to eq([product1, product2, product3, product4])
    end
  end

  describe "#tiers" do
    context "for tiered membership" do
      it "returns proper variants" do
        product = create(:membership_product)

        tiers = product.tiers

        expect(tiers.size).to eq 1
        expect(tiers.first).to eq product.variant_categories.alive.first.variants.first
      end
    end

    context "for a non-membership product" do
      it "returns nil" do
        product = create(:product)
        expect(product.tier_category).to be_nil
      end
    end
  end

  describe "#default_tier" do
    context "for a tiered membership" do
      it "returns the first tier" do
        product = create(:membership_product)
        second_tier = create(:variant, variant_category: product.tier_category)

        tier = product.tiers.first

        expect(product.default_tier).to eq tier
        expect(product.default_tier).not_to eq second_tier
      end
    end

    context "for a non-membership product" do
      it "returns nil" do
        product = create(:product)

        expect(product.default_tier).to be_nil
      end
    end
  end

  describe "#default_tier" do
    context "for a tiered membership" do
      it "returns the first tier" do
        product = create(:membership_product)
        second_tier = create(:variant, variant_category: product.tier_category)

        tier = product.tiers.first

        expect(product.default_tier).to eq tier
        expect(product.default_tier).not_to eq second_tier
      end
    end

    context "for a non-membership product" do
      it "returns nil" do
        product = create(:product)

        expect(product.default_tier).to be_nil
      end
    end
  end

  describe "#tier_category" do
    context "for tiered membership" do
      it "returns the tier category" do
        product = create(:membership_product)

        category = product.tier_category

        expect(category).to be_a VariantCategory
        expect(category.link).to eq product
        expect(category.title).to eq "Tier"
      end
    end

    context "for a non-membership product" do
      it "returns nil" do
        product = create(:product)
        expect(product.tier_category).to be_nil
      end
    end
  end

  describe "has_downloadable_content?" do
    let(:product) { create(:product) }
    before do
      @product_with_files = create(:product_with_files)
      @preorder_product = create(:product, is_in_preorder_state: true)
    end

    it "returns false if product has no files" do
      expect(product.has_downloadable_content?).to eq(false)
    end

    it "returns false if product is a pre-order" do
      product.update!(is_in_preorder_state: true)
      product.product_files << create(:streamable_video, stream_only: true)

      expect(product.has_downloadable_content?).to eq(false)
    end

    it "returns false if product has only stream-only files" do
      product.product_files << create(:streamable_video, stream_only: true)

      expect(product.has_downloadable_content?).to eq(false)
    end

    it "returns true if product has at least one file that is not stream-only" do
      product.product_files << create(:readable_document)
      product.product_files << create(:streamable_video, stream_only: true)

      expect(product.has_downloadable_content?).to eq(true)
    end
  end

  describe "#save_shipping_destinations" do
    before do
      @product = create(:product)
    end

    it "clears all entries if the input is empty for an unpublished product" do
      @product.deleted_at = Time.current

      expect(@product.alive?).to eq(false)
      expect(@product.shipping_destinations.size).to eq(0)

      shipping_destination1 = ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 20, multiple_items_rate_cents: 10)
      shipping_destination2 = ShippingDestination.new(country_code: Compliance::Countries::DEU.alpha2, one_item_rate_cents: 10, multiple_items_rate_cents: 5)

      @product.shipping_destinations << shipping_destination1 << shipping_destination2
      @product.save!

      expect(@product.shipping_destinations.size).to eq(2)
      expect(@product.shipping_destinations.alive.size).to eq(2)

      @product.save_shipping_destinations!([])
      @product.reload

      expect(@product.shipping_destinations.size).to eq(2)
      expect(@product.shipping_destinations.alive.size).to eq(0)
    end

    it "raises an exception if the input is empty for an product" do
      expect(@product.shipping_destinations.size).to eq(0)
      expect(@product.alive?).to eq(true)

      shipping_destination1 = ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 20, multiple_items_rate_cents: 10)
      shipping_destination2 = ShippingDestination.new(country_code: Compliance::Countries::DEU.alpha2, one_item_rate_cents: 10, multiple_items_rate_cents: 5)

      @product.shipping_destinations << shipping_destination1 << shipping_destination2
      @product.save!

      expect(@product.shipping_destinations.size).to eq(2)
      expect(@product.shipping_destinations.alive.size).to eq(2)

      expect do
        @product.save_shipping_destinations!([])
      end.to raise_error(Link::LinkInvalid)
    end

    it "saves the entry if input has unique country values" do
      shipping_destination_inputs = []
      shipping_destination_inputs << { "country_code" => Compliance::Countries::USA.alpha2, "one_item_rate" => 20, "multiple_items_rate" => 10 }
      shipping_destination_inputs << { "country_code" => Compliance::Countries::DEU.alpha2, "one_item_rate" => 10, "multiple_items_rate" => 0 }

      expect(@product.shipping_destinations.size).to eq(0)

      @product.save_shipping_destinations!(shipping_destination_inputs)

      @product.reload

      expect(@product.shipping_destinations.size).to eq(2)
      expect(@product.shipping_destinations.alive.size).to eq(2)

      expect(@product.shipping_destinations.first.country_code).to eq("US")
      expect(@product.shipping_destinations.first.one_item_rate_cents).to eq(2000)
      expect(@product.shipping_destinations.first.multiple_items_rate_cents).to eq(1000)

      expect(@product.shipping_destinations.second.country_code).to eq("DE")
      expect(@product.shipping_destinations.second.one_item_rate_cents).to eq(1000)
      expect(@product.shipping_destinations.second.multiple_items_rate_cents).to eq(0)
    end

    it "saves the entry if the values are specified in cents" do
      shipping_destination_inputs = []
      shipping_destination_inputs << { "country_code" => Compliance::Countries::USA.alpha2, "one_item_rate_cents" => 2000, "multiple_items_rate_cents" => 1000 }
      shipping_destination_inputs << { "country_code" => Compliance::Countries::DEU.alpha2, "one_item_rate_cents" => 1000, "multiple_items_rate_cents" => 0 }

      expect(@product.shipping_destinations.size).to eq(0)

      @product.save_shipping_destinations!(shipping_destination_inputs)

      @product.reload

      expect(@product.shipping_destinations.size).to eq(2)
      expect(@product.shipping_destinations.alive.size).to eq(2)

      expect(@product.shipping_destinations.first.country_code).to eq("US")
      expect(@product.shipping_destinations.first.one_item_rate_cents).to eq(2000)
      expect(@product.shipping_destinations.first.multiple_items_rate_cents).to eq(1000)

      expect(@product.shipping_destinations.second.country_code).to eq("DE")
      expect(@product.shipping_destinations.second.one_item_rate_cents).to eq(1000)
      expect(@product.shipping_destinations.second.multiple_items_rate_cents).to eq(0)
    end

    it "rejects duplicated and raises an error" do
      shipping_destination_inputs = []
      shipping_destination_inputs << { "country_code" => Compliance::Countries::USA.alpha2, "one_item_rate" => 20, "multiple_items_rate" => 10 }
      shipping_destination_inputs << { "country_code" => Compliance::Countries::USA.alpha2, "one_item_rate" => 10, "multiple_items_rate" => 0 }

      expect(@product.shipping_destinations.size).to eq(0)

      expect do
        @product.save_shipping_destinations!(shipping_destination_inputs)
      end.to raise_error(Link::LinkInvalid)
    end

    it "removes entries that do not exist in the input" do
      shipping_destination1 = ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 20, multiple_items_rate_cents: 10)
      shipping_destination2 = ShippingDestination.new(country_code: Compliance::Countries::DEU.alpha2, one_item_rate_cents: 10, multiple_items_rate_cents: 5)

      @product.shipping_destinations << shipping_destination1 << shipping_destination2
      @product.save!

      expect(@product.shipping_destinations.size).to eq(2)
      expect(@product.shipping_destinations.alive.size).to eq(2)

      @product.save_shipping_destinations!([{ "country_code" => Compliance::Countries::USA.alpha2, "one_item_rate" => 20, "multiple_items_rate" => 10 }])

      expect(@product.shipping_destinations.size).to eq(3)
      expect(@product.shipping_destinations.alive.size).to eq(1)
    end

    it "resurrects deactivated entries if input reconfigures them" do
      shipping_destination1 = ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 20, multiple_items_rate_cents: 10)
      shipping_destination2 = ShippingDestination.new(country_code: Compliance::Countries::DEU.alpha2, one_item_rate_cents: 10, multiple_items_rate_cents: 5)

      @product.shipping_destinations << shipping_destination1 << shipping_destination2
      @product.save!

      expect(@product.shipping_destinations.size).to eq(2)
      expect(@product.shipping_destinations.alive.size).to eq(2)

      @product.save_shipping_destinations!([{ "country_code" => Compliance::Countries::USA.alpha2, "one_item_rate" => 10, "multiple_items_rate" => 0 }])
      @product.reload

      expect(@product.shipping_destinations.size).to eq(3)
      expect(@product.shipping_destinations.alive.size).to eq(1)

      @product.save_shipping_destinations!([{ "country_code" => Product::Shipping::ELSEWHERE, "one_item_rate" => 20, "multiple_items_rate" => 10 }])

      expect(@product.shipping_destinations.size).to eq(3)
      expect(@product.shipping_destinations.alive.size).to eq(1)
      expect(@product.shipping_destinations.alive.first.country_code).to eq("ELSEWHERE")
      expect(@product.shipping_destinations.alive.first.one_item_rate_cents).to eq(2000)
      expect(@product.shipping_destinations.alive.first.multiple_items_rate_cents).to eq(1000)
    end

    describe "virtual countries" do
      it "saves the entry if input has unique country values and sets is_virtual_country" do
        shipping_destination_inputs = []
        shipping_destination_inputs << { "country_code" => ShippingDestination::Destinations::EUROPE, "one_item_rate" => 20, "multiple_items_rate" => 10 }

        expect(@product.shipping_destinations.size).to eq(0)

        @product.save_shipping_destinations!(shipping_destination_inputs)

        @product.reload

        expect(@product.shipping_destinations.size).to eq(1)
        expect(@product.shipping_destinations.alive.size).to eq(1)

        expect(@product.shipping_destinations.first.country_code).to eq("EUROPE")
        expect(@product.shipping_destinations.first.one_item_rate_cents).to eq(2000)
        expect(@product.shipping_destinations.first.multiple_items_rate_cents).to eq(1000)
        expect(@product.shipping_destinations.first.is_virtual_country).to eq(true)
      end
    end
  end

  describe "prices migration" do
    before do
      @product = create(:product, price_cents: 200)
      @subscription_product = create(:product, is_recurring_billing: true, subscription_duration: "monthly", price_cents: 200)
    end

    it "has the proper buy price" do
      price = @product.prices.last
      expect(price.price_cents).to eq 200
      expect(price.currency).to eq "usd"
      expect(price.is_rental).to eq false
      expect(price.recurrence).to eq nil
    end

    it "has the proper buy price when the price changes" do
      @product.price_cents = 300
      @product.save!

      expect(@product.prices.alive.count).to eq 1

      price = @product.prices.alive.last
      expect(price.price_cents).to eq 300
      expect(price.currency).to eq "usd"
      expect(price.is_rental).to eq false
      expect(price.recurrence).to eq nil
    end

    it "has the proper rent price" do
      expect do
        @product.rental_price_cents = 100
        @product.purchase_type = :buy_and_rent
        @product.save!
      end.to change { @product.prices.alive.count }.by(1)

      buy_price = @product.prices.is_buy.last
      expect(buy_price.price_cents).to eq 200
      expect(buy_price.currency).to eq "usd"
      expect(buy_price.is_rental).to eq false
      expect(buy_price.recurrence).to eq nil

      rental_price = @product.prices.is_rental.last
      expect(rental_price.price_cents).to eq 100
      expect(rental_price.currency).to eq "usd"
      expect(rental_price.is_rental).to eq true
      expect(rental_price.recurrence).to eq nil
    end

    it "only has the rental price if it's rent-only" do
      expect do
        @product.rental_price_cents = 100
        @product.purchase_type = :buy_and_rent
        @product.save!
      end.to change { @product.prices.alive.count }.by(1)

      expect do
        @product.purchase_type = :rent_only
        @product.save!
      end.to change { @product.prices.alive.count }.by(-1)

      rental_price = @product.prices.alive.is_rental.last
      expect(rental_price.price_cents).to eq 100
      expect(rental_price.currency).to eq "usd"
      expect(rental_price.is_rental).to eq true
      expect(rental_price.recurrence).to eq nil
    end

    it "has the proper price for subscriptions" do
      price = @subscription_product.prices.alive.last
      expect(price.price_cents).to eq 200
      expect(price.currency).to eq "usd"
      expect(price.is_rental).to eq false
      expect(price.recurrence).to eq BasePrice::Recurrence::MONTHLY
    end

    it "has the proper price for subscriptions when the price changes" do
      @subscription_product.price_cents = 500
      @subscription_product.save!

      price = @subscription_product.prices.alive.last
      expect(price.price_cents).to eq 500
      expect(price.currency).to eq "usd"
      expect(price.is_rental).to eq false
      expect(price.recurrence).to eq BasePrice::Recurrence::MONTHLY
    end

    it "has the proper currency" do
      product = create(:product, price_cents: 200, price_currency_type: "jpy")
      price = product.prices.alive.last
      expect(price.price_cents).to eq 200
      expect(price.currency).to eq "jpy"
      expect(price.is_rental).to eq false
      expect(price.recurrence).to eq nil
    end
  end

  describe "require_shipping_for_physical" do
    it "does not create a physical product with require_shipping false" do
      expect(build(:product, is_physical: true, require_shipping: false).valid?).to be(false)
    end

    it "has error if require shipping is false for a physical product" do
      product = create(:physical_product)
      product.require_shipping = false
      expect do
        product.save!
      end.to raise_error(ActiveRecord::RecordInvalid)
      expect(product.errors.full_messages.to_sentence).to eq "Shipping form is required for physical products."
    end
  end

  describe "twitter_share_url" do
    it "uris escape the product name" do
      product = create(:product, name: "you & i")
      expect(product.twitter_share_url).to eq "https://twitter.com/intent/tweet?text=I+got+you+%26+i+on+%40Gumroad:%20#{product.long_url}"
    end
  end

  describe "duration_multiple_of_price_options" do
    before do
      @product = create(:subscription_product, subscription_duration: "yearly", duration_in_months: 12)
    end

    it "allows a null duration_in_months" do
      @product.duration_in_months = nil
      expect do
        @product.save!
      end.to_not raise_error
    end

    it "allows a duration_in_months that is a multiple of 12 for yearly" do
      @product.duration_in_months = 24
      expect do
        @product.save!
      end.to_not raise_error
    end

    it "errors if duration_in_months is 0" do
      @product.duration_in_months = 0
      expect do
        @product.save!
      end.to raise_error(ActiveRecord::RecordInvalid)
      expect(@product.errors.full_messages.to_sentence).to eq("Your subscription length in months must be a number greater than zero.")
    end

    it "errors if duration_in_months is not a multiple of 12 for yearly" do
      @product.duration_in_months = 5
      expect do
        @product.save!
      end.to raise_error(ActiveRecord::RecordInvalid)
      expect(@product.errors.full_messages.to_sentence).to eq("Your subscription length in months must be a multiple of #{12} because you have selected a payment option of yearly payments.")
    end
  end

  describe "reorder_previews" do
    let!(:product) { create(:product) }
    let!(:preview1) { create(:asset_preview, link: product) }
    let!(:preview2) { create(:asset_preview, link: product) }
    let!(:preview3) { create(:asset_preview, link: product) }
    let!(:preview4) { create(:asset_preview, link: product) }
    let!(:preview5) { create(:asset_preview, link: product) }
    let!(:preview6) { create(:asset_preview, link: product) }
    let!(:preview7) { create(:asset_preview, link: product) }
    let!(:preview8) { create(:asset_preview, link: product) }

    it "updates positions of previews" do
      product.reorder_previews(
        preview1.guid => 1,
        preview2.guid => 2,
        preview3.guid => 3,
        preview4.guid => 0, # put preview4 first
        preview5.guid => 4,
        preview6.guid => 5,
        preview7.guid => 6,
        preview8.guid => 7,
      )

      expect(product.display_asset_previews.pluck(:id)).to eq [
        preview4.id, # expect it to be first and the rest to be in the same order
        preview1.id,
        preview2.id,
        preview3.id,
        preview5.id,
        preview6.id,
        preview7.id,
        preview8.id,
      ]
    end
  end

  describe "#rated_as_adult?" do
    it "returns true if the product is set to is_adult" do
      product = create(:product, is_adult: true)
      expect(product.rated_as_adult?).to eq(true)
    end

    it "returns true if the user profile is set to all_adult_products" do
      product = create(:product, user: create(:user, all_adult_products: true))
      expect(product.rated_as_adult?).to eq(true)
    end

    it "returns true if the product contains any adult keywords" do
      product = create(:product)
      allow(product).to receive(:has_adult_keywords?).and_return(true)
      expect(product.rated_as_adult?).to eq(true)
    end
  end

  describe "#has_adult_keywords?" do
    it "returns true if product fields have adult keywords" do
      product_1 = build(:product, name: "abs punch product")
      product_2 = build(:product, description: "NSFW product")
      product_3 = build(:product, user: create(:user, bio: "NSFW stuff"))
      product_4 = build(:product, user: create(:user, name: "NsfwUser"))
      product_5 = build(:product, user: create(:user, username: "futa123"))
      expect(product_1.has_adult_keywords?).to eq(true)
      expect(product_2.has_adult_keywords?).to eq(true)
      expect(product_3.has_adult_keywords?).to eq(true)
      expect(product_4.has_adult_keywords?).to eq(true)
      expect(product_5.has_adult_keywords?).to eq(true)
    end

    context "classifies description as expected" do
      shared_examples_for "test" do |description, adult|
        it "\"#{description}\" as #{'non-' unless adult}adult" do
          expect(build(:product, description:).has_adult_keywords?).to eq(adult)
        end
      end

      # not "squirt"
      include_examples "test", "squirtle is a Pokémon", false
      # not "adult"
      include_examples "test", "small fuéta", false
      # not "nsfw"
      include_examples "test", "ns fw", false
      # not "yuri"
      include_examples "test", "Yuri Gagarin was a great astronaut", false
      # not "tentacle"
      include_examples "test", "Tentacle Monster Hat", false

      # nude
      include_examples "test", "nude2screen", true
      # hentai
      include_examples "test", "Click here for #HotHentaiComics!", true
    end
  end

  describe "#has_content?" do
    context "for a product with rich content" do
      let(:product) { create(:product) }

      context "when the product has no rich content" do
        it "returns `false`" do
          expect(product.alive_rich_contents.count).to eq(0)
          expect(product.has_content?).to eq(false)

          create(:rich_content, entity: product, description: [])
          expect(product.reload.alive_rich_contents.count).to eq(1)
          expect(product.has_content?).to eq(false)
        end
      end

      context "when the product has rich content" do
        it "returns `true`" do
          create(:rich_content, entity: product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "hello" }] }])
          expect(product.reload.alive_rich_contents.count).to eq(1)
          expect(product.has_content?).to eq(true)
        end
      end
    end
  end

  describe "currencies" do
    # to prevent issues like https://github.com/gumroad/web/issues/15021
    # when ours and Money's subunit treatment are diverging

    CURRENCY_CHOICES.keys.each do |currency_type|
      it "formats #{currency_type.to_s.upcase} currency properly" do
        link = create(:product, price_currency_type: currency_type, price_cents: CURRENCY_CHOICES[currency_type][:min_price] * 10)

        original_cents = link.price_cents

        # if we assign the current unit price again, this should be a no-op
        # when/if it actually changes the price, that is a sign of divergent subunit treatment
        link.price_range = link.price_formatted_without_dollar_sign

        expect(link.price_cents).to eq original_cents
      end
    end
  end

  describe "#statement_description" do
    it "returns creator's name if present, otherwise the username" do
      creator = create(:user, name: "name", username: "username")
      product = create(:product, user: creator)
      expect(product.statement_description).to eq("name")

      creator.update!(name: nil)
      expect(product.statement_description).to eq("username")
    end
  end

  describe "#gumroad_amount_for_paypal_order" do
    let(:creator) { create(:user) }
    let(:product) { create(:product, user: creator) }

    it "returns 10% of the given amount" do
      expect(product.gumroad_amount_for_paypal_order(amount_cents: 10_00)).to eq(100)
      expect(product.gumroad_amount_for_paypal_order(amount_cents: 10_00, was_recommended: true)).to eq(100)
    end

    it "adds discover fee minus 10%" do
      product.update!(discover_fee_per_thousand: 500)

      expect(product.gumroad_amount_for_paypal_order(amount_cents: 10_00)).to eq(100)
      expect(product.gumroad_amount_for_paypal_order(amount_cents: 10_00, was_recommended: true)).to eq(500)
    end

    context "for affiliate sales" do
      let(:gumroad_fee) { 100 }
      let(:discover_fee) { 100 }

      context "by a direct affiliate" do
        let(:affiliate) { create(:direct_affiliate, seller: creator, affiliate_basis_points: 2500, products: [product]) }
        let(:affiliate_fee) { 250 }

        it "adds the affiliate fee" do
          expect(product.gumroad_amount_for_paypal_order(amount_cents: 10_00, affiliate_id: affiliate.id)).to eq(gumroad_fee + affiliate_fee)
        end

        it "does not add the affiliate fee for Discover sales" do
          expect(product.gumroad_amount_for_paypal_order(amount_cents: 10_00, affiliate_id: affiliate.id, was_recommended: true)).to eq(gumroad_fee)
        end
      end

      context "by a global affiliate" do
        let(:affiliate) { create(:user).global_affiliate }
        let(:affiliate_fee) { 100 }
        let(:product) { create(:product, :recommendable) }

        it "adds the affiliate fee for a global affiliate" do
          expect(product.gumroad_amount_for_paypal_order(amount_cents: 10_00, affiliate_id: affiliate.id)).to eq(gumroad_fee + affiliate_fee)
        end

        it "still adds the affiliate fee for Discover sales" do
          expect(product.gumroad_amount_for_paypal_order(amount_cents: 10_00, affiliate_id: affiliate.id, was_recommended: true)).to eq(gumroad_fee + affiliate_fee)
        end
      end
    end

    it "adds vat amount if vat is present" do
      affiliate_user = create(:affiliate_user)
      direct_affiliate = create(:direct_affiliate, affiliate_user:, seller: creator, affiliate_basis_points: 2500, products: [product])
      expect(product.gumroad_amount_for_paypal_order(amount_cents: 10_00, affiliate_id: direct_affiliate.id,
                                                     vat_cents: 30)).to eq(380) # 1_00 (flat 10% fee) + 2_50 (25% affiliate fee) + 30 (30c vat)
    end
  end

  describe "#free_trial_duration" do
    it "returns nil if free trial is not enabled" do
      product = build(:product)
      expect(product.free_trial_duration).to eq nil
    end

    it "returns the free trial duration if free trial is enabled" do
      product = build(:product, free_trial_enabled: true, free_trial_duration_amount: 1, free_trial_duration_unit: :week)
      expect(product.free_trial_duration).to eq 1.week

      product.free_trial_duration_amount = 3
      expect(product.free_trial_duration).to eq 3.weeks

      product.free_trial_duration_unit = :month
      expect(product.free_trial_duration).to eq 3.months
    end
  end

  describe "#has_customizable_price_option?" do
    context "for a non-tiered membership product" do
      it "returns true if the product has a customizable price" do
        product = build(:product, customizable_price: true)
        expect(product.has_customizable_price_option?).to eq true
      end

      it "returns false if the product does not have a customizable price" do
        product = build(:product, customizable_price: false)
        expect(product.has_customizable_price_option?).to eq false
      end
    end

    context "for a tiered membership product" do
      let(:product) { create(:membership_product) }

      it "returns false if the product has no customizable price tiers" do
        expect(product.has_customizable_price_option?).to eq false
      end

      it "returns true if the product has a customizable price tier" do
        product.default_tier.update!(customizable_price: true)
        expect(product.has_customizable_price_option?).to eq true
      end

      it "returns false if the product has only deleted customizable price tiers" do
        create(:variant, variant_category: product.tier_category, customizable_price: true, deleted_at: Time.current)
        expect(product.has_customizable_price_option?).to eq false
      end
    end
  end

  describe "#recurrence_price_enabled?" do
    it "returns true if the product has a live price for the given recurrence" do
      product = create(:product)
      create(:price, link: product, recurrence: "monthly")

      expect(product.recurrence_price_enabled?("monthly")).to eq true
    end

    it "returns false if the product does not have a live price for the given recurrence" do
      product = create(:product)
      expect(product.recurrence_price_enabled?("monthly")).to eq false

      create(:price, link: product, recurrence: "monthly", deleted_at: 1.day.ago)
      expect(product.recurrence_price_enabled?("monthly")).to eq false
    end
  end

  describe "#has_multiple_variants?" do
    context "for a physical product" do
      let(:product) { create(:physical_product) }

      it "returns false if the product has only a default SKU" do
        expect(product.has_multiple_variants?).to eq false
      end

      it "returns false if the product has only a default SKU and deleted custom SKUs" do
        create(:sku, link: product, deleted_at: Time.current)
        expect(product.has_multiple_variants?).to eq false
      end

      it "returns true if the product has a default SKU and a single live custom SKU" do
        # if there are any custom SKUs, those SKUs are used and the default SKU is not
        create(:sku, link: product)
        expect(product.has_multiple_variants?).to eq false
      end

      it "returns true if the product has a default SKU and multiple live custom SKUs" do
        create_list(:sku, 2, link: product)
        expect(product.has_multiple_variants?).to eq true
      end
    end

    context "for a non-physical product" do
      let(:product) { create(:product) }
      let(:category) { create(:variant_category, link: product) }

      it "returns false if the product has no live variants" do
        create(:variant, variant_category: category, deleted_at: Time.current)
        expect(product.has_multiple_variants?).to eq false
      end

      it "returns false if the product has a single live variant" do
        create(:variant, variant_category: category)
        expect(product.has_multiple_variants?).to eq false
      end

      it "returns true if the product has a single variant category with multiple live variants" do
        create_list(:variant, 2, variant_category: category)
        expect(product.has_multiple_variants?).to eq true
      end

      it "returns true if the product has multiple variant categories with live variants" do
        other_category = create(:variant_category, link: product)
        create(:variant, variant_category: other_category)
        create(:variant, variant_category: category)

        expect(product.has_multiple_variants?).to eq true
      end
    end
  end

  describe "associations" do
    context "has many `product_integrations`" do
      it "returns alive and deleted product_integrations" do
        integration_1 = create(:circle_integration)
        integration_2 = create(:circle_integration)
        product = create(:product, active_integrations: [integration_1, integration_2])
        expect do
          product.product_integrations.find_by(integration: integration_1).mark_deleted!
        end.to change { product.product_integrations.count }.by(0)
        expect(product.product_integrations.pluck(:integration_id)).to match_array [integration_1, integration_2].map(&:id)
      end
    end

    context "has many `live_product_integrations`" do
      it "does not return deleted product_integrations" do
        integration_1 = create(:circle_integration)
        integration_2 = create(:circle_integration)
        product = create(:product, active_integrations: [integration_1, integration_2])
        expect do
          product.product_integrations.find_by(integration: integration_1).mark_deleted!
        end.to change { product.live_product_integrations.count }.by(-1)
        expect(product.live_product_integrations.pluck(:integration_id)).to match_array [integration_2.id]
      end
    end

    context "has many `active_integrations`" do
      it "does not return deleted integrations" do
        integration_1 = create(:circle_integration)
        integration_2 = create(:circle_integration)
        product = create(:product, active_integrations: [integration_1, integration_2])
        expect do
          product.product_integrations.find_by(integration: integration_1).mark_deleted!
        end.to change { product.active_integrations.count }.by(-1)
        expect(product.active_integrations.pluck(:integration_id)).to match_array [integration_2.id]
      end
    end

    context "has many `product_cached_values`" do
      it "returns all product cached values" do
        product = create(:product)
        product_cached_value = create(:product_cached_value, product:)
        expired_product_cached_value = create(:product_cached_value, product:, expired: true)

        expect(product.reload.product_cached_values).to contain_exactly(product_cached_value, expired_product_cached_value)
      end
    end

    describe "affiliates" do
      let(:product) { create(:product) }
      let(:direct_affiliate) { create(:direct_affiliate) }
      let(:global_affiliate) { create(:user).global_affiliate }
      let!(:product_affiliates) do
        [create(:product_affiliate, product:, affiliate: direct_affiliate),
         create(:product_affiliate, product:, affiliate: global_affiliate)]
      end

      it "has many `product_affiliates`" do
        expect(product.product_affiliates).to match_array product_affiliates
      end

      it "has many `affiliates`" do
        expect(product.affiliates).to match_array [direct_affiliate, global_affiliate]
      end

      it "has many `direct_affiliates`" do
        expect(product.direct_affiliates).to match_array [direct_affiliate]
      end

      it "has many `global_affiliates`" do
        expect(product.global_affiliates).to match_array [global_affiliate]
      end
    end

    describe "variants" do
      let(:product) { create(:product) }
      let(:variant_category) { create(:variant_category, link: product) }
      let(:alive_variant) { create(:variant, variant_category:) }
      let(:deleted_variant) { create(:variant, variant_category:, deleted_at: 1.hour.ago) }

      it "has many `variants`" do
        expect(product.variants).to match_array [alive_variant, deleted_variant]
      end

      it "has many `alive_variants`" do
        expect(product.alive_variants).to match_array [alive_variant]
      end
    end
  end

  describe "#has_active_paid_variants?" do
    before do
      @product = create(:product, user: create(:user))
      @variant_category = create(:variant_category, link: @product)
      create(:variant, variant_category: @variant_category, price_difference_cents: 0)
    end

    it "returns false when there are no active paid variants" do
      expect(@product.has_active_paid_variants?).to eq(false)
    end

    it "returns true when there are active paid variants" do
      create(:variant, variant_category: @variant_category, price_difference_cents: 100)

      expect(@product.has_active_paid_variants?).to eq(true)
    end
  end

  describe "#html_safe_description" do
    subject(:html_safe_description) { product.html_safe_description }

    context "when description contains URLs" do
      let(:product) { create(:product_with_pdf_file, description: "Check it out at https://gumroad.com") }

      it "automatically turns links into HTML anchor tags" do
        is_expected.to eq("Check it out at <a href=\"https://gumroad.com\" target=\"_blank\" rel=\"noopener noreferrer nofollow\">https://gumroad.com</a>")
        is_expected.to be_html_safe
      end
    end

    context "when description is empty" do
      let(:product) { create(:product_with_pdf_file, description: "") }

      it { is_expected.to be_nil }
    end

    context "when description contains unsafe tags and attributes" do
      let(:product) { create(:product, description: "<h1><span>Heading in span</span></h1><b>Bold</b><p><style>color: red</style><strong class=\"something\">Strong</strong></p><p onclick=\"alert('hi')\"><em>Italic</em></p><p><u>Underline</u></p><p><s>Strkethrough</s></p><h1>Heading 1</h1><h2>Heading 2</h2><h3>Heading 3</h3><h4>Heading 4</h4><h5>Heading 5</h5><h6>Heading 6</h6><pre><code>Code</code></pre><ul><li>Bullet list</li></ul><ol><li>Numbered list</li></ol><p>Horizontal line</p><hr><blockquote><p>Quote</p></blockquote><p><a target=\"_blank\" rel=\"noopener noreferrer nofollow\" href=\"https://example.com/\">Link</a></p><figure><img src=\"https://example.com/test.jpg\"><p class=\"figcaption\">Image</p></figure><div class=\"tiptap__raw\"><div><div style=\"left: 0; width: 100%; height: 0; position: relative; padding-bottom: 56.25%;\"><iframe src=\"//cdn.iframe.ly/api/iframe?url=https%3A%2F%2Fyoutu.be%2Fu80Ey6lSRyE&amp;key=1234\" style=\"top: 0; left: 0; width: 100%; height: 100%; position: absolute; border: 0;\" allowfullscreen=\"\" scrolling=\"no\" allow=\"accelerometer *; clipboard-write *; encrypted-media *; gyroscope *; picture-in-picture *; web-share *;\"></iframe></div></div></div><div class=\"tiptap__raw\"><div class=\"iframely-embed\" style=\"max-width: 550px;\"><div class=\"iframely-responsive\" style=\"padding-bottom: 56.25%;\"><a href=\"https://twitter.com/shl/status/1678978982019223553\" data-iframely-url=\"//cdn.iframe.ly/api/iframe?url=https%3A%2F%2Ftwitter.com%2Fshl%2Fstatus%2F1678978982019223553&amp;key=1234\"></a></div></div><script async=\"\" src=\"//cdn.iframe.ly/embed.js\" charset=\"utf-8\"></script></div><p><br></p><a class=\"tiptap__button button primary\" target=\"_blank\" rel=\"noopener noreferrer nofollow\" href=\"https://example.com/\">Button</a><a href=\"javascript:void(0)\">Click me</a><br><script>var a = 2;</script><iframe src=\"https://example.com\">Lorem ipsum</iframe><public-file-embed id=\"1234567890abcdef\"></public-file-embed>") }

      it "removes unsafe and unknown tags and attributes from the description" do
        is_expected.to eq %(<h1><span>Heading in span</span></h1><b>Bold</b><p><strong class="something">Strong</strong></p><p><em>Italic</em></p><p><u>Underline</u></p><p><s>Strkethrough</s></p><h1>Heading 1</h1><h2>Heading 2</h2><h3>Heading 3</h3><h4>Heading 4</h4><h5>Heading 5</h5><h6>Heading 6</h6><pre><code>Code</code></pre><ul><li>Bullet list</li></ul><ol><li>Numbered list</li></ol><p>Horizontal line</p><hr><blockquote><p>Quote</p></blockquote><p><a target="_blank" rel="noopener noreferrer nofollow" href="https://example.com/">Link</a></p><figure><img src="https://example.com/test.jpg"><p class="figcaption">Image</p></figure><div class="tiptap__raw"><div><div style="width:100%;height:0;position:relative;padding-bottom:56.25%;"><iframe src="http://cdn.iframe.ly/api/iframe?url=https%3A%2F%2Fyoutu.be%2Fu80Ey6lSRyE&amp;key=1234" style="top: 0; left: 0; width: 100%; height: 100%; position: absolute; border: 0;" allowfullscreen="" scrolling="no" allow="accelerometer *; clipboard-write *; encrypted-media *; gyroscope *; picture-in-picture *; web-share *;"></iframe></div></div></div><div class="tiptap__raw">\n<div class="iframely-embed" style="max-width:550px;"><div class="iframely-responsive" style="padding-bottom:56.25%;"><a href="https://twitter.com/shl/status/1678978982019223553" data-iframely-url="//cdn.iframe.ly/api/iframe?url=https%3A%2F%2Ftwitter.com%2Fshl%2Fstatus%2F1678978982019223553&amp;key=1234"></a></div></div>\n<script src="http://cdn.iframe.ly/embed.js" charset="utf-8"></script>\n</div><p><br></p><a class="tiptap__button button primary" target="_blank" rel="noopener noreferrer nofollow" href="https://example.com/">Button</a><a>Click me</a><br><public-file-embed id="1234567890abcdef"></public-file-embed>)
        is_expected.to be_html_safe
      end
    end

    context "when description contains urls without a protocol" do
      let(:product) { create(:product, description: "<iframe src='//cdn.iframe.ly'></iframe><img src='//example.com/image.jpg'>") }

      it "adds protocol to the urls" do
        expect(product.html_safe_description).to eq("<iframe src=\"http://cdn.iframe.ly\"></iframe><img src=\"http://example.com/image.jpg\">")
      end
    end

    context "when description contains a script from an untrusted source" do
      let(:product) { create(:product, description: "some text<script src='https://untrusted.example.com/script.js'></script>evil script") }

      it "removes the script tag" do
        expect(html_safe_description).to eq("some textevil script")
      end
    end

    context "when description contains a script from iframe.ly" do
      let(:product) { create(:product, description: "some text<script src='https://cdn.iframe.ly/script.js'></script>evil script") }

      it "removes script tag if path is not embed.js" do
        expect(product.html_safe_description).to eq("some textevil script")
      end

      it "keeps script tag if path is embed.js" do
        product = create(:product, description: "some text<script src='https://cdn.iframe.ly/embed.js'></script>evil script")
        expect(product.html_safe_description).to eq("some text<script src=\"https://cdn.iframe.ly/embed.js\"></script>evil script")
      end
    end
  end

  describe "#sku_title" do
    it "is \"Version\" when there are no current categories" do
      product = create(:product)
      expect(product.sku_title).to eq("Version")
    end

    it "is the categories concatenated together when there are current categories" do
      product = create(:product)
      create(:variant_category, title: "Color", link: product)
      create(:variant_category, title: "Size", link: product)
      expect(product.sku_title).to eq("Color - Size")
    end
  end

  describe "#options" do
    it "returns SKUs if the product has SKUs enabled" do
      product = create(:physical_product)
      sku1 = product.skus.create(price_difference_cents: 1, name: "SKU 1")
      sku2 = product.skus.create(price_difference_cents: 2, name: "SKU 2")
      expect(product.options).to contain_exactly(sku1.to_option, sku2.to_option)
    end

    it "returns variants if the product does not have SKUs" do
      product = create(:product_with_digital_versions)
      expect(product.options).to contain_exactly(
        product.alive_variants.first.to_option,
        product.alive_variants.second.to_option
      )
    end
  end

  describe "#enable_transcode_videos_on_purchase!" do
    it "sets transcode_videos_on_purchase to true" do
      product = create(:product)

      expect do
        product.enable_transcode_videos_on_purchase!
      end.to change { product.transcode_videos_on_purchase }.from(false).to(true)
    end
  end

  describe "#auto_transcode_videos?" do
    before do
      @product = create(:product)
    end

    context "when user.auto_transcode_videos? returns true" do
      before do
        allow(@product.user).to receive(:auto_transcode_videos?).and_return(true)
      end

      it "returns true" do
        expect(@product.auto_transcode_videos?).to eq true
      end
    end

    context "when product has successful sales" do
      before do
        allow(@product).to receive(:has_successful_sales?).and_return(true)
      end

      it "returns true" do
        expect(@product.auto_transcode_videos?).to eq true
      end
    end
  end

  describe "#permalink_overlaps_with_other_sellers?" do
    before do
      create(:product, unique_permalink: "abc", custom_permalink: "xyz")
    end

    it "returns true when custom permalink overlaps with products from other sellers" do
      product = create(:product, custom_permalink: "abc")

      expect(product.permalink_overlaps_with_other_sellers?).to eq true
    end

    it "returns true when unique permalink overlaps with products from other sellers" do
      product = create(:product, unique_permalink: "xyz")

      expect(product.permalink_overlaps_with_other_sellers?).to eq true
    end
    it "returns false when permalinks don't overlap with products from other sellers" do
      product = create(:product, unique_permalink: "def", custom_permalink: "ghi")

      expect(product.permalink_overlaps_with_other_sellers?).to eq false
    end
  end

  describe "#ppp_details" do
    before do
      @product = create(:product, user: create(:user, purchasing_power_parity_enabled: true))
      @lv_ip = "109.110.31.255"
      @us_ip = "101.198.198.0"
      ppp_service = PurchasingPowerParityService.new
      ppp_service.set_factor("LV", 0.5)
      ppp_service.set_factor("US", 1)
    end

    context "when the PPP factor doesn't exist" do
      before do
        allow_any_instance_of(GeoIp::Result).to receive(:country_code).and_return("FAKE")
      end

      it "returns nil" do
        expect(@product.ppp_details(@lv_ip)).to eq(nil)
      end
    end

    context "with purchasing_power_parity_disabled" do
      before do
        @product.update!(purchasing_power_parity_disabled: true)
      end

      it "returns nil" do
        expect(@product.ppp_details(@lv_ip)).to eq(nil)
      end
    end

    context "when the PPP factor is 1" do
      it "returns nil" do
        expect(@product.ppp_details(@us_ip)).to eq(nil)
      end
    end

    context "when the PPP factor exists and isn't 1" do
      it "returns the PPP details" do
        expect(@product.ppp_details(@lv_ip)).to eq(
          {
            country: "Latvia",
            factor: 0.5,
            minimum_price: 99,
          }
        )
      end
    end
  end

  describe "purchasing_power_parity_enabled?" do
    before do
      @product = create(:product, user: create(:user))
    end

    context "when the user doesn't have purchasing_power_parity_enabled" do
      it "returns false when purchasing_power_parity_disabled is false" do
        expect(@product.purchasing_power_parity_enabled?).to eq(false)
      end

      it "returns false when purchasing_power_parity_disabled is true" do
        @product.update! purchasing_power_parity_disabled: true

        expect(@product.purchasing_power_parity_enabled?).to eq(false)
      end
    end

    context "when the user has purchasing_power_parity_enabled" do
      before do
        @product.user.update! purchasing_power_parity_enabled: true
      end

      it "returns true when purchasing_power_parity_disabled is false" do
        expect(@product.purchasing_power_parity_enabled?).to eq(true)
      end

      it "returns false when purchasing_power_parity_disabled is true" do
        @product.update! purchasing_power_parity_disabled: true

        expect(@product.purchasing_power_parity_enabled?).to eq(false)
      end
    end
  end

  describe "#has_offer_codes?" do
    let(:product) { create(:product) }

    context "when the product has offer codes" do
      let!(:offer_code) { create(:offer_code, user: product.user, products: [product]) }

      context "when the user-level flag is enabled" do
        before do
          product.user.update!(display_offer_code_field: true)
        end

        it "returns true" do
          expect(product.has_offer_codes?).to eq(true)
        end
      end

      context "when the user-level flag is disabled" do
        it "returns false" do
          expect(product.has_offer_codes?).to eq(false)
        end
      end
    end

    context "when the product doesn't have offer codes" do
      context "when the user-level flag is enabled" do
        before do
          product.user.update!(display_offer_code_field: true)
        end

        it "returns false" do
          expect(product.has_offer_codes?).to eq(false)
        end
      end

      context "when the user-level flag is disabled" do
        it "returns false" do
          expect(product.has_offer_codes?).to eq(false)
        end
      end
    end
  end

  describe "#cross_sells" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }
    let(:cross_sell1) { create(:upsell, seller:, selected_products: [product], cross_sell: true) }
    let(:cross_sell2) { create(:upsell, seller:, universal: true, cross_sell: true) }
    let (:cross_sell3) { create(:upsell, seller:, cross_sell: true) }

    it "returns the product's cross-sells" do
      expect(product.cross_sells).to eq([cross_sell1, cross_sell2])
    end
  end

  describe "#find_or_initialize_product_refund_policy" do
    context "when the product has a refund policy" do
      let(:product_refund_policy) { create(:product_refund_policy) }

      it "returns the product's refund policy" do
        expect(product_refund_policy.product.find_or_initialize_product_refund_policy).to eq(product_refund_policy)
      end
    end

    context "when the product doesn't have a refund policy" do
      let(:product) { create(:product) }

      it "returns a new refund policy" do
        product_refund_policy = product.find_or_initialize_product_refund_policy

        expect(product_refund_policy).to be_a(ProductRefundPolicy)
        expect(product_refund_policy.persisted?).to be false
        expect(product_refund_policy.product).to eq(product)
        expect(product_refund_policy.seller).to eq(product.user)
      end
    end
  end

  describe "#purchase_info_for_product_page" do
    let(:product) { create(:product, is_in_preorder_state:) }

    context "when there is a matching user" do
      let(:user) { create(:user) }

      context "when the purchase is not a preorder" do
        let(:is_in_preorder_state) { false }

        context "when the user has a previous purchase" do
          let!(:purchase) { create(:purchase, link: product, purchaser: user) }

          it "returns the purchase" do
            expect(product.purchase_info_for_product_page(user, nil)[:id]).to eq(purchase.external_id)
          end

          it "returns purchase_info" do
            expect(product.purchase_info_for_product_page(user, nil)).to eq(purchase.purchase_info)
          end
        end

        context "when the user has a previous gift sender purchase" do
          let!(:purchase) { create(:purchase, link: product, purchaser: user, is_gift_sender_purchase: true) }

          it "returns nil" do
            expect(product.purchase_info_for_product_page(user, nil)).to eq(nil)
          end
        end

        context "when the user has a previous gift receiver purchase" do
          let!(:purchase) { create(:purchase, :gift_receiver, link: product, purchaser: user) }
          it "returns the purchase" do
            expect(product.purchase_info_for_product_page(user, nil)[:id]).to eq(purchase.external_id)
          end
        end
      end

      context "when the purchase is a preorder" do
        let(:is_in_preorder_state) { true }

        context "when the user has a previous purchase" do
          let!(:purchase) { create(:preorder_authorization_purchase, link: product, purchaser: user) }

          it "returns the purchase" do
            expect(product.purchase_info_for_product_page(user, nil)[:id]).to eq(purchase.external_id)
          end
        end

        context "when the user has a previous gift sender purchase" do
          let!(:purchase) { create(:preorder_authorization_purchase, link: product, purchaser: user, is_gift_sender_purchase: true) }

          it "returns nil" do
            expect(product.purchase_info_for_product_page(user, nil)).to eq(nil)
          end
        end

        context "when the user has a previous gift receiver purchase" do
          let!(:purchase) { create(:preorder_authorization_purchase, :gift_receiver, link: product, purchaser: user) }
          it "returns the purchase" do
            expect(product.purchase_info_for_product_page(user, nil)[:id]).to eq(purchase.external_id)
          end
        end
      end
    end

    context "when there is no user but a browser guid" do
      let(:user) { nil }

      context "when the purchase is not a preorder" do
        let(:is_in_preorder_state) { false }

        context "when there is a previous purchase with the browser guid" do
          let!(:purchase) { create(:purchase, link: product) }

          it "returns the purchase" do
            expect(product.purchase_info_for_product_page(user, purchase.browser_guid)[:id]).to eq(purchase.external_id)
          end
        end

        context "when there is a previous gift sender purchase with the browser guid" do
          let!(:purchase) { create(:purchase, link: product, is_gift_sender_purchase: true) }

          it "returns nil" do
            expect(product.purchase_info_for_product_page(user, purchase.browser_guid)).to eq(nil)
          end
        end

        context "when there is a previous purchase received as a gift with the browser guid" do
          let!(:purchase) { create(:purchase, :gift_receiver, link: product) }
          it "returns the purchase" do
            expect(product.purchase_info_for_product_page(user, purchase.browser_guid)[:id]).to eq(purchase.external_id)
          end
        end
      end

      context "when the purchase is a preorder" do
        let(:is_in_preorder_state) { true }

        context "when there is a previous purchase with the browser guid" do
          let!(:purchase) { create(:preorder_authorization_purchase, link: product) }

          it "returns the purchase" do
            expect(product.purchase_info_for_product_page(user, purchase.browser_guid)[:id]).to eq(purchase.external_id)
          end
        end

        context "when there is a previous gift sender purchase with the browser guid" do
          let!(:purchase) { create(:preorder_authorization_purchase, link: product, is_gift_sender_purchase: true) }

          it "returns nil" do
            expect(product.purchase_info_for_product_page(user, purchase.browser_guid)).to eq(nil)
          end
        end
      end
    end

    context "when there is a non-matching user and a matching browser guid" do
      let(:user) { create(:user) }

      context "when the purchase is not a preorder" do
        let(:is_in_preorder_state) { false }

        context "when there is a previous purchase with the browser guid" do
          let!(:purchase) { create(:purchase, link: product) }

          it "returns the purchase" do
            expect(product.purchase_info_for_product_page(user, purchase.browser_guid)[:id]).to eq(purchase.external_id)
          end
        end

        context "when there is a previous gift sender purchase with the browser guid" do
          let!(:purchase) { create(:purchase, link: product, is_gift_sender_purchase: true) }

          it "returns nil" do
            expect(product.purchase_info_for_product_page(user, purchase.browser_guid)).to eq(nil)
          end
        end

        context "when there is a previous purchase received as a gift with the browser guid" do
          let!(:purchase) { create(:purchase, :gift_receiver, link: product) }
          it "returns the purchase" do
            expect(product.purchase_info_for_product_page(user, purchase.browser_guid)[:id]).to eq(purchase.external_id)
          end
        end
      end

      context "when the purchase is a preorder" do
        let(:is_in_preorder_state) { true }

        context "when there is a previous purchase with the browser guid" do
          let!(:purchase) { create(:preorder_authorization_purchase, link: product) }

          it "returns the purchase" do
            expect(product.purchase_info_for_product_page(user, purchase.browser_guid)[:id]).to eq(purchase.external_id)
          end
        end

        context "when there is a previous gift sender purchase with the browser guid" do
          let!(:purchase) { create(:preorder_authorization_purchase, link: product, is_gift_sender_purchase: true) }

          it "returns nil" do
            expect(product.purchase_info_for_product_page(user, purchase.browser_guid)).to eq(nil)
          end
        end

        context "when there is a previous purchase received as a gift with the browser guid" do
          let!(:purchase) { create(:preorder_authorization_purchase, :gift_receiver, link: product) }
          it "returns the purchase" do
            expect(product.purchase_info_for_product_page(user, purchase.browser_guid)[:id]).to eq(purchase.external_id)
          end
        end
      end
    end

    context "when there is no user or browser guid" do
      let(:purchase) { create(:purchase, link: product) }
      let(:is_in_preorder_state) { false }

      it "returns nil" do
        expect(product.purchase_info_for_product_page(nil, nil)).to eq(nil)
      end
    end
  end

  describe "service product validation" do
    context "seller of a service product is not eligible for service products" do
      let(:commission) { build(:product, native_type: "commission") }

      it "adds a validation error for a service product" do
        commission.save
        expect(commission).to_not be_valid
        expect(commission.errors.full_messages.first).to eq("Service products are disabled until your account is 30 days old.")
      end
    end

    context "seller of a service product is eligible for service products" do
      let(:user) { create(:user, :eligible_for_service_products) }
      let(:commission) { build(:product, user:, native_type: "commission", price_cents: 200) }

      it "does not add a validation error for a service product" do
        commission.save
        expect(commission).to be_valid
      end
    end
  end

  describe "#show_in_sections!" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }
    let!(:profile_section1) { create(:seller_profile_products_section, seller:, shown_products: [product.id]) }
    let!(:profile_section2) { create(:seller_profile_products_section, seller:) }

    it "updates the profile sections correctly" do
      seller.reload
      expect { product.show_in_sections!([profile_section2.external_id]) }
        .to change { profile_section1.reload.shown_products }.from([product.id]).to([])
        .and change { profile_section2.reload.shown_products }.from([]).to([product.id])
    end
  end

  describe "#variants_or_skus" do
    context "SKUs are enabled" do
      let(:product) { create(:physical_product) }

      context "no non-default SKUs" do
        it "returns an empty array" do
          expect(product.variants_or_skus).to eq([])
        end
      end

      context "one or more SKUs" do
        let!(:sku) { create(:sku, link: product) }

        it "returns the product's SKUs" do
          expect(product.variants_or_skus).to eq([sku])
        end
      end
    end

    describe "SKUs are disabled" do
      let(:product) { create(:product) }
      let!(:variant) { create(:variant, variant_category: create(:variant_category, link: product)) }

      context "no variants" do
        before { variant.update!(deleted_at: Time.current) }

        it "returns an empty array" do
          expect(product.variants_or_skus).to eq([])
        end
      end

      context "one or more variants" do
        it "returns those variants" do
          expect(product.variants_or_skus).to eq([variant])
        end
      end
    end
  end

  describe "#has_embedded_license_key?" do
    it "returns false when the product-level rich content does not have an embedded license key" do
      product = create(:product)
      create(:rich_content, entity: product)

      expect(product.has_embedded_license_key?).to be(false)
    end

    it "returns true when the product-level rich content has an embedded license key" do
      product = create(:product)
      create(:rich_content, entity: product, description: [{ "type" => "licenseKey" }])

      expect(product.has_embedded_license_key?).to be(true)
    end

    it "returns false when none of the variant-level rich content has an embedded license key" do
      product = create(:product)
      variant = create(:variant, variant_category: create(:variant_category, link: product))
      create(:rich_content, entity: variant)

      expect(product.has_embedded_license_key?).to be(false)
    end

    it "returns true when at least one of the variant-level rich content has an embedded license key" do
      product = create(:product)
      variant_category = create(:variant_category, link: product)
      variant1 = create(:variant, variant_category:)
      variant2 = create(:variant, variant_category:)
      create(:rich_content, entity: variant1, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Some text" }] }])
      create(:rich_content, entity: variant2, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Variant 2 text" }] }, { "type" => "licenseKey" }])

      expect(product.has_embedded_license_key?).to be(true)
    end
  end

  describe "#has_another_collaborator?" do
    let(:product) { create(:product) }
    let!(:collaborator_for_another_product) { create(:collaborator, products: [create(:product)]) }

    before do
      # ensure affiliates are ignored
      create(:direct_affiliate, products: [product])
      create(:product_affiliate, product:, affiliate: create(:user).global_affiliate)
    end

    it "returns true if the product has any live collaborators, regardless of invitation status" do
      # Has no collaborators at all.
      expect(product.has_another_collaborator?).to eq(false)
      expect(product.has_another_collaborator?(collaborator: collaborator_for_another_product)).to eq(false)

      # Has a pending collaborator.
      collaborator = create(:collaborator, :with_pending_invitation, products: [product])
      expect(product.has_another_collaborator?).to eq(true)
      expect(product.has_another_collaborator?(collaborator:)).to eq(false)
      expect(product.has_another_collaborator?(collaborator: collaborator_for_another_product)).to eq(true)

      # Has a confirmed collaborator.
      collaborator.collaborator_invitation.destroy!
      expect(product.has_another_collaborator?).to eq(true)
      expect(product.has_another_collaborator?(collaborator:)).to eq(false)
      expect(product.has_another_collaborator?(collaborator: collaborator_for_another_product)).to eq(true)

      # Has a soft-deleted collaborator.
      collaborator.mark_deleted!
      expect(product.has_another_collaborator?).to eq(false)
      expect(product.has_another_collaborator?(collaborator:)).to eq(false)
      expect(product.has_another_collaborator?(collaborator: collaborator_for_another_product)).to eq(false)
    end
  end

  describe "#generate_product_files_archives!" do
    it "generates file group archives for a product with product-level rich content" do
      product = create(:product)
      file1 = create(:product_file, link: product)
      file2 = create(:product_file, link: product)
      description = [
        { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => SecureRandom.uuid }, "content" => [
          { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
          { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
        ] }]
      create(:rich_content, entity: product, description:)

      expect { product.generate_product_files_archives! }.to change { product.product_files_archives.folder_archives.alive.size }.by(1)
    end

    it "generates file group archives for a product with variant-level rich content" do
      product = create(:product)
      category = create(:variant_category, link: product)
      version1 = create(:variant, variant_category: category, name: "V1")
      version2 = create(:variant, variant_category: category, name: "V2")

      file1 = create(:product_file, display_name: "File 1")
      file2 = create(:product_file, display_name: "File 2")
      file3 = create(:product_file, display_name: "File 3")
      file4 = create(:product_file, display_name: "File 4")
      product.product_files = [file1, file2, file3, file4]
      version1.product_files = [file1, file2]
      version2.product_files = [file3, file4]
      version1_rich_content_description = [{ "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => SecureRandom.uuid }, "content" => [
        { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
        { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
      ] }]
      version2_rich_content_description = [{ "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => SecureRandom.uuid }, "content" => [
        { "type" => "fileEmbed", "attrs" => { "id" => file3.external_id, "uid" => SecureRandom.uuid } },
        { "type" => "fileEmbed", "attrs" => { "id" => file4.external_id, "uid" => SecureRandom.uuid } },
      ] }]
      create(:rich_content, entity: version1, description: version1_rich_content_description)
      create(:rich_content, entity: version2, description: version2_rich_content_description)

      expect do
        expect do
          product.generate_product_files_archives!
        end.to_not change {
          product.product_files_archives.folder_archives.size
        }
      end.to change { version1.product_files_archives.folder_archives.alive.size }.by(1)
      .and change { version2.product_files_archives.folder_archives.alive.size }.by(1)
    end

    it "regenerates file group archives containing the provided files" do
      product = create(:product)
      file1 = create(:product_file, link: product)
      file2 = create(:product_file, link: product)
      folder_id = SecureRandom.uuid
      description = [
        { "type" => "fileEmbedGroup", "attrs" => { "name" => "folder 1", "uid" => folder_id }, "content" => [
          { "type" => "fileEmbed", "attrs" => { "id" => file1.external_id, "uid" => SecureRandom.uuid } },
          { "type" => "fileEmbed", "attrs" => { "id" => file2.external_id, "uid" => SecureRandom.uuid } },
        ] }]
      create(:rich_content, entity: product, description:)

      archive = product.product_files_archives.create!(folder_id:, product_files: product.product_files)
      archive.mark_in_progress!
      archive.mark_ready!

      expect { product.generate_product_files_archives! }.to_not change { archive.reload.deleted? }
      expect { product.generate_product_files_archives!(for_files: [file1]) }.to change { archive.reload.deleted? }.from(false).to(true)
      expect(product.product_files_archives.folder_archives.alive.size).to eq(1)
      expect(product.product_files_archives.folder_archives.alive.first.folder_id).to eq(folder_id)
    end
  end

  describe "#has_product_level_rich_content?" do
    it "returns true for products with product-level rich content, and false otherwise" do
      product = create(:product)
      physical_product = create(:product, is_physical: true, require_shipping: true)

      product_where_variants_share_rich_content = create(:product, has_same_rich_content_for_all_variants: true)
      create(:variant, variant_category: create(:variant_category, link: product_where_variants_share_rich_content), name: "V1")

      product_where_variants_do_not_share_rich_content = create(:product)
      create(:variant, variant_category: create(:variant_category, link: product_where_variants_do_not_share_rich_content), name: "V1")

      expect([product, physical_product, product_where_variants_share_rich_content].all?(&:has_product_level_rich_content?)).to eq(true)
      expect(product_where_variants_do_not_share_rich_content.has_product_level_rich_content?).to eq(false)
    end
  end

  describe "#percentage_revenue_cut_for_user" do
    let(:product) { create(:product, is_collab: false) }

    context "for a non-collab" do
      it "returns 100 for the creator" do
        expect(product.percentage_revenue_cut_for_user(product.user)).to eq(100)
      end

      it "returns 0 for other users" do
        expect(product.percentage_revenue_cut_for_user(create(:user))).to eq(0)
      end
    end

    context "for a collab" do
      let(:product) { create(:product, :is_collab, collaborator_cut: 45_00) }

      it "returns the collaborator's cut for the collaborator, only if the invitation has been accepted" do
        seller = product.user
        affiliate_user = product.collaborator.affiliate_user

        expect(product.percentage_revenue_cut_for_user(seller)).to eq(55)
        expect(product.percentage_revenue_cut_for_user(affiliate_user)).to eq(45)

        product.collaborator.create_collaborator_invitation!
        expect(product.percentage_revenue_cut_for_user(seller)).to eq(100)
        expect(product.percentage_revenue_cut_for_user(affiliate_user)).to eq(0)
      end

      it "returns 0 for other users" do
        expect(product.percentage_revenue_cut_for_user(create(:user))).to eq(0)
      end
    end
  end

  describe "#unpublish!" do
    let(:product) { create(:product) }

    it "unpublishes the product" do
      freeze_time do
        product.unpublish!(is_unpublished_by_admin: true)

        product.reload
        expect(product.purchase_disabled_at).to eq Time.current
        expect(product.is_unpublished_by_admin).to eq true
      end
    end
  end

  describe "#alive?" do
    it "returns true if the product is available for purchase" do
      expect(build(:product).alive?).to eq true
    end

    it "returns false if the product has been banned, deleted, or purchase is disabled" do
      expect(build(:product, banned_at: Time.current).alive?).to eq false
      expect(build(:product, deleted_at: Time.current).alive?).to eq false
      expect(build(:product, purchase_disabled_at: Time.current).alive?).to eq false
    end
  end

  describe "#published?" do
    it "returns true if the product is available for purchase and not a draft" do
      expect(build(:product).published?).to eq true
    end

    it "returns false if the product is a draft, deleted, or unavailable for purchase" do
      expect(build(:product, purchase_disabled_at: Time.current).published?).to eq false
      expect(build(:product, deleted_at: Time.current).alive?).to eq false
      expect(build(:product, draft: true).published?).to eq false
    end
  end

  describe "commission validations" do
    let(:seller) { create(:user, :eligible_for_service_products) }
    let(:commission) { create(:product, user: seller, native_type: Link::NATIVE_TYPE_COMMISSION, price_cents: 0) }

    context "price is 0" do
      it "doesn't add an error" do
        expect(commission).to be_valid
      end
    end

    context "price is less than double the currency minimum" do
      before { commission.price_cents = 100 }

      it "doesn't add an error" do
        expect(commission).to_not be_valid
        expect(commission.errors.full_messages.first).to eq("The commission price must be at least 1.98 USD.")
      end
    end

    context "price is at least double the currency minimum" do
      before { commission.price_cents = 198 }

      it "doesn't add an error" do
        expect(commission).to be_valid
      end
    end
  end

  describe "coffee validations" do
    let(:seller) { create(:user, :eligible_for_service_products) }
    let(:coffee) { build(:product, user: seller, native_type: Link::NATIVE_TYPE_COFFEE) }

    context "user has a coffee product" do
      before { create(:product, user: seller, native_type: Link::NATIVE_TYPE_COFFEE, purchase_disabled_at: Time.current) }

      it "adds an error" do
        expect(coffee).to_not be_valid
        expect(coffee.errors.full_messages.first).to eq("You can only have one coffee product.")
      end
    end

    context "user doesn't have a coffee product" do
      before { create(:product, user: seller, native_type: Link::NATIVE_TYPE_COFFEE, deleted_at: Time.current) }

      it "doesn't add an error" do
        expect(coffee).to be_valid
      end
    end

    context "with zero price" do
      let(:coffee) { create(:product, user: seller, native_type: Link::NATIVE_TYPE_COFFEE) }
      let(:variant_category) { create(:variant_category, link: coffee) }

      it "validates minimum price for variants" do
        variant = build(:variant, variant_category: variant_category, price_difference_cents: 0)
        expect(variant).not_to be_valid
      end

      it "prevents updating to zero price" do
        variant = create(:variant, variant_category: variant_category, price_difference_cents: 100)
        variant.price_difference_cents = 0
        expect(variant).not_to be_valid
      end
    end
  end

  describe "calls validations" do
    context "call has no durations" do
      let(:call) { create(:call_product, durations: []) }

      it "adds an error" do
        expect(call).to be_invalid
        expect(call.errors.full_messages.first).to eq("Calls must have at least one duration")
      end

      it "does not add an error if product is deleted" do
        call.deleted_at = Time.current
        expect(call).to be_valid
        expect(call.errors).to be_empty
      end
    end

    context "call has durations" do
      let(:call) { create(:call_product, durations: [30]) }

      it "does not add an error" do
        expect(call).to be_valid
      end
    end
  end

  describe "support email validations" do
    let(:product) { build(:product) }

    context "when support_email is nil" do
      it "is valid" do
        product.support_email = nil
        expect(product).to be_valid
      end
    end

    context "when support_email is blank" do
      it "is invalid" do
        product.support_email = ""
        expect(product).not_to be_valid
      end
    end

    context "when support_email has a valid email format" do
      it "is valid" do
        product.support_email = "support@example.com"
        expect(product).to be_valid
      end
    end

    context "when support_email has an invalid email format" do
      it "is invalid without @ symbol" do
        product.support_email = "invalidemail"
        expect(product).not_to be_valid
        expect(product.errors[:support_email]).to include("is invalid")
      end

      it "is invalid without domain" do
        product.support_email = "user@"
        expect(product).not_to be_valid
        expect(product.errors[:support_email]).to include("is invalid")
      end
    end
  end

  describe "#can_gift?" do
    let(:product) { build(:product) }

    context "for a regular product" do
      it "returns true" do
        expect(product.can_gift?).to eq true
      end
    end

    context "when has a preorder state" do
      before { product.is_in_preorder_state = true }

      it "returns false" do
        expect(product.can_gift?).to eq false
      end
    end

    context "when it is a recurring product" do
      before { product.is_recurring_billing = true }

      it "returns true" do
        expect(product.can_gift?).to eq true
      end
    end
  end

  describe "#quantity_enabled" do
    it "can only be false for membership product" do
      membership_product = build(:membership_product)

      membership_product.quantity_enabled = true
      expect(membership_product).to be_invalid
      expect(membership_product.errors.full_messages).to include("Customers cannot be allowed to choose a quantity for this product.")

      membership_product.quantity_enabled = false
      expect(membership_product).to be_valid
    end

    it "can only be false for call products" do
      call_product = build(:call_product)

      call_product.quantity_enabled = true
      expect(call_product).to be_invalid
      expect(call_product.errors.full_messages).to include("Customers cannot be allowed to choose a quantity for this product.")

      call_product.quantity_enabled = false
      expect(call_product).to be_valid
    end

    it "can be true for other products" do
      product = build(:product)

      product.quantity_enabled = true
      expect(product).to be_valid

      product.quantity_enabled = false
      expect(product).to be_valid
    end
  end

  describe "#can_enable_quantity?" do
    let(:call_product) { build(:call_product) }
    let(:membership_product) { build(:membership_product) }
    let(:physical_product) { build(:physical_product) }

    it "returns true for non-membership and non-call products" do
      expect(call_product.can_enable_quantity?).to eq false
      expect(membership_product.can_enable_quantity?).to eq false
      expect(physical_product.can_enable_quantity?).to eq true
    end
  end

  describe "#require_captcha?" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }

    context "seller is older than 6 months" do
      before { seller.update(created_at: 6.months.ago - 1.day) }

      it "returns false" do
        expect(product.require_captcha?).to eq false
      end
    end

    context "seller is younger than 6 months" do
      before { seller.update(created_at: 6.months.ago + 1.day) }

      it "returns true" do
        expect(product.require_captcha?).to eq true
      end
    end
  end

  describe ".eligible_for_content_upsells" do
    let!(:regular_product) { create(:product_with_file_and_preview) }
    let!(:membership_product) { create(:membership_product) }
    let!(:product_with_variants) { create(:product_with_digital_versions) }
    let!(:archived_product) { create(:product, archived: true) }

    it "returns visible non-membership products including those with variants" do
      expect(Link.eligible_for_content_upsells).to match_array([regular_product, product_with_variants])
    end
  end

  describe "installment plan" do
    let!(:product) { create(:product, price_cents: 1000) }
    let!(:installment_plan) { create(:product_installment_plan, link: product, number_of_installments: 2) }

    it "re-validates the installment plan whenever the product is updated" do
      product.price_cents = 99
      expect(product).not_to be_valid
      expect(product.errors.full_messages).to include("Installment plan The minimum price for each installment must be at least 0.99 USD.")
    end
  end

  describe "#toggle_community_chat" do
    let(:product) { create(:product) }

    context "when enabling community chat" do
      it "enables community chat and creates a new community if none exists" do
        expect do
          product.toggle_community_chat!(true)
        end.to change { product.reload.community_chat_enabled }.from(false).to(true)
          .and change { product.reload.communities.count }.by(1)

        expect(product.active_community).to eq(product.communities.last)
      end

      it "enables community chat and restores a deleted community if one exists" do
        community = create(:community, resource: product, deleted_at: 1.day.ago)

        expect(product.active_community).to be_nil

        expect do
          product.toggle_community_chat!(true)
        end.to change { product.reload.community_chat_enabled }.from(false).to(true)
          .and change { community.reload.deleted_at }.to(nil)

        expect(product.active_community).to eq(community)
      end

      it "does nothing if community chat is already enabled" do
        product.update!(community_chat_enabled: true)
        create(:community, resource: product)

        expect do
          expect do
            product.toggle_community_chat!(true)
          end.not_to change { product.reload.community_chat_enabled }
        end.not_to change { product.communities.count }
      end
    end

    context "when disabling community chat" do
      before do
        product.update!(community_chat_enabled: true)
        create(:community, resource: product)
      end

      it "disables community chat and marks the associated active community as deleted" do
        expect(product.active_community).to eq(product.communities.last)

        expect do
          product.toggle_community_chat!(false)
        end.to change { product.reload.community_chat_enabled }.from(true).to(false)
          .and change { product.reload.communities.alive.count }.from(1).to(0)

        expect(product.active_community).to be_nil
      end

      it "does nothing if community chat is already disabled" do
        product.update!(community_chat_enabled: false)

        expect do
          expect do
            product.toggle_community_chat!(false)
          end.not_to change { product.reload.community_chat_enabled }
        end.not_to change { product.communities.count }
      end
    end
  end
end
