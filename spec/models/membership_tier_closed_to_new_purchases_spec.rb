# frozen_string_literal: true

require "spec_helper"

describe "Closing a membership tier to new purchases" do
  let(:seller) { create(:user) }
  let(:product) { create(:membership_product, user: seller) }
  let(:tier) { product.tiers.first }
  let!(:lapsing_purchase) { create(:membership_purchase, link: product, tier:) }
  let!(:remaining_purchase) { create(:membership_purchase, link: product, tier:) }
  let!(:product_file) { create(:product_file, link: product) }
  let!(:archive) { create(:product_files_archive, link: nil, variant: tier) }

  before do
    tier.product_files << product_file
    tier.update!(max_purchase_count: 3)
  end

  # Same path as a real renewal, stopping short of the charge processor.
  def renewal_of(subscription)
    purchase = subscription.build_purchase
    purchase.purchase_state = "in_progress"
    purchase.skip_preparing_for_charge = true
    purchase.process!
    purchase
  end

  def new_purchase_of(tier)
    purchase = build(:purchase, link: product, variant_attributes: [tier], is_original_subscription_purchase: true, purchase_state: "in_progress")
    purchase.save
    purchase
  end

  def lapse(purchase)
    expect { purchase.subscription.deactivate! }.to change { tier.reload.sales_count_for_inventory }.by(-1)
  end

  context "with the feature on for the seller" do
    before do
      Feature.activate_user(:close_membership_tier_to_new_buyers, seller)
      tier.update!(closed_to_new_purchases: true)
    end

    it "keeps the tier closed after a lapse frees inventory" do
      lapse(lapsing_purchase)
      tier.reload

      expect(tier.quantity_left).to be > 0
      expect(tier.closed_to_new_purchases?).to be(true)
      expect(tier.available?).to be(false)
      expect(product.reload.options.find { _1[:id] == tier.external_id }[:quantity_left]).to eq(0)
      buyer_payload = tier.as_json(for_views: true)
      expect(buyer_payload["quantity_left"]).to eq(0)
      expect(buyer_payload["sold_out"]).to be(true)
      expect(product.variant_list[:categories].first[:options].find { _1["id"] == tier.external_id }).to include("quantity_left" => 0, "sold_out" => true)
      seller_payload = tier.as_json(for_views: true, for_seller: true)
      expect(seller_payload["quantity_left"]).to eq(tier.quantity_left)
      expect(seller_payload["sold_out"]).to be(false)

      purchase = new_purchase_of(tier)
      expect(purchase.error_code).to eq(PurchaseErrorCode::VARIANT_SOLD_OUT)
      expect(purchase.errors.full_messages).to include("Sold out, please go back and pick another option.")
    end

    it "renews the remaining subscriber at their current rate" do
      lapse(lapsing_purchase)
      subscription = remaining_purchase.subscription.reload

      renewal = renewal_of(subscription)

      expect(renewal.errors.full_messages).to be_empty
      expect(renewal.error_code).to be_nil
      expect(renewal.persisted?).to be(true)
      expect(renewal.variant_attributes).to eq([tier])
      expect(renewal.price_cents).to eq(subscription.current_subscription_price_cents)
    end

    it "does not delete the tier, its files, or its archives" do
      lapse(lapsing_purchase)
      new_purchase_of(tier)

      expect(tier.reload).to be_alive
      expect(tier.product_files.alive).to eq([product_file])
      expect(archive.reload).to be_alive
      expect(DeleteProductFilesArchivesWorker.jobs.size).to eq(0)
      expect(DeleteProductRichContentWorker.jobs.size).to eq(0)
    end

    it "logs the rejection without buyer details" do
      allow(Rails.logger).to receive(:info).and_call_original

      purchase = new_purchase_of(tier)

      expect(Rails.logger).to have_received(:info).with(
        "[Purchase] new purchase rejected reason=tier_closed_to_new_purchases product_id=#{product.external_id} variant_ids=#{tier.external_id}"
      ).once
      expect(Rails.logger).not_to have_received(:info).with(a_string_including(purchase.email))
    end

    it "shows the tier as sold out on a direct link and keeps the fallback off it" do
      open_tier = create(:variant, variant_category: product.tier_category, name: "Open")

      direct = product.reload.cart_item(option: tier.external_id)
      expect(direct[:option]).to include(id: tier.external_id, quantity_left: 0)

      expect(product.cart_item({})[:option][:id]).to eq(open_tier.external_id)
    end

    it "keeps the subscriber's own tier selectable in the subscription manager" do
      props = CheckoutPresenter.new(logged_in_user: nil, ip: nil).subscription_manager_props(subscription: remaining_purchase.subscription)
      own_tier = props[:product][:options].find { _1[:id] == tier.external_id }

      expect(own_tier[:quantity_left]).to eq(tier.quantity_left)
      expect(own_tier[:quantity_left]).to be > 0
    end

    it "rejects changing an existing subscriber onto the closed tier" do
      other_tier = create(:variant, variant_category: product.tier_category, name: "Other")
      subscriber = create(:membership_purchase, link: product, tier: other_tier)

      expect do
        subscriber.subscription.update_current_plan!(new_variants: [tier], new_price: subscriber.subscription.price, skip_preparing_for_charge: true)
      end.to raise_error(Subscription::UpdateFailed, "Sold out, please go back and pick another option.")
      expect(subscriber.subscription.reload.original_purchase.variant_attributes).to eq([other_tier])
    end

    it "lets a subscriber with no stored tier stay on the closed default tier" do
      remaining_purchase.update!(variant_attributes: [])
      subscription = remaining_purchase.subscription

      new_purchase = subscription.update_current_plan!(new_variants: [tier], new_price: subscription.price, skip_preparing_for_charge: true)

      expect(new_purchase.errors).to be_empty
      expect(new_purchase.variant_attributes).to eq([tier])
    end

    it "still rejects a subscriber with no stored tier who moves onto another closed tier" do
      remaining_purchase.update!(variant_attributes: [])
      other_tier = create(:variant, variant_category: product.tier_category, name: "Other", closed_to_new_purchases: true)

      expect do
        remaining_purchase.subscription.update_current_plan!(new_variants: [other_tier], new_price: remaining_purchase.subscription.price, skip_preparing_for_charge: true)
      end.to raise_error(Subscription::UpdateFailed, "Sold out, please go back and pick another option.")
    end

    it "lets an existing subscriber on the closed tier update their plan" do
      subscription = remaining_purchase.subscription

      new_purchase = subscription.update_current_plan!(new_variants: [tier], new_price: subscription.price, skip_preparing_for_charge: true)

      expect(new_purchase.errors).to be_empty
      expect(new_purchase.variant_attributes).to eq([tier])
    end

    it "reopens the tier when the seller clears the setting" do
      tier.update!(closed_to_new_purchases: false)

      expect(tier.reload.available?).to be(true)
      expect(new_purchase_of(tier).error_code).not_to eq(PurchaseErrorCode::VARIANT_SOLD_OUT)
    end
  end

  context "with the feature off for the seller" do
    before { tier.update!(closed_to_new_purchases: true) }

    it "ignores the stored setting, so the same lapse leaves the tier selectable" do
      lapse(lapsing_purchase)
      tier.reload

      expect(tier.closed_to_new_purchases?).to be(true)
      expect(tier.available?).to be(true)
      expect(product.reload.options.find { _1[:id] == tier.external_id }[:quantity_left]).to eq(tier.quantity_left)
      expect(new_purchase_of(tier).error_code).not_to eq(PurchaseErrorCode::VARIANT_SOLD_OUT)
    end
  end

  it "never closes a version of a non-membership product" do
    Feature.activate_user(:close_membership_tier_to_new_buyers, seller)
    version = create(:variant, variant_category: create(:variant_category, link: create(:product, user: seller)), closed_to_new_purchases: true)

    expect(version.closed_to_new_buyers?).to be(false)
    expect(version.available?).to be(true)
  end
end
