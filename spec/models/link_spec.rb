# frozen_string_literal: true

require "spec_helper"

describe Link do
  describe "#publish! with an apply-to-all affiliate" do
    it "creates the assignment through ProductAffiliate" do
      seller = create(:user)
      affiliate = create(:direct_affiliate, seller:, apply_to_all_products: true)
      product = create(:product, user: seller, draft: true)
      expect(ProductAffiliate).to receive(:create_if_missing!).with(affiliate:, product:).and_call_original

      expect do
        product.publish!
      end.to have_enqueued_mail(AffiliateMailer, :notify_direct_affiliate_of_new_product).with(affiliate.id, product.id)

      expect(affiliate.product_affiliates.find_by(link_id: product.id)).to be_present
    end

    it "does not add apply-to-all affiliates to a collab product" do
      seller = create(:user)
      affiliate = create(:direct_affiliate, seller:, apply_to_all_products: true)
      product = create(:product, user: seller, draft: true, is_collab: true)

      product.publish!

      expect(product.reload).to be_published
      expect(affiliate.product_affiliates.find_by(link_id: product.id)).to be_nil
    end

    it "uses the current collaboration state" do
      seller = create(:user)
      affiliate = create(:direct_affiliate, seller:, apply_to_all_products: true)
      product = create(:product, user: seller, draft: true, is_collab: true)
      Link.find(product.id).update_flag!(:is_collab, false, true)

      product.publish!

      expect(product.reload).to be_published
      expect(affiliate.product_affiliates.find_by(link_id: product.id)).to be_present
    end

    it "preserves concurrent changes to other flags" do
      seller = create(:user)
      product = create(:product, user: seller, draft: true, display_product_reviews: false)
      allow(product).to receive(:auto_transcode_videos?).and_return(false)
      Link.find(product.id).update_flag!(:display_product_reviews, true, true)

      product.publish!

      expect(product.reload).to be_display_product_reviews
      expect(product).to be_transcode_videos_on_purchase
    end

    it "merges the caller's flag changes into the current flags" do
      seller = create(:user)
      product = create(:product, user: seller, draft: true, display_product_reviews: false, should_show_sales_count: false)
      allow(product).to receive(:auto_transcode_videos?).and_return(false)
      product.display_product_reviews = true
      Link.find(product.id).update_flag!(:should_show_sales_count, true, true)

      product.publish!

      expect(product.reload).to be_display_product_reviews
      expect(product).to be_should_show_sales_count
    end

    it "does not notify an affiliate when the assignment exists" do
      seller = create(:user)
      affiliate = create(:direct_affiliate, seller:, apply_to_all_products: true)
      product = create(:product, user: seller, draft: true)
      create(:product_affiliate, affiliate:, product:)

      expect do
        product.publish!
      end.not_to have_enqueued_mail(AffiliateMailer, :notify_direct_affiliate_of_new_product)

      expect(ProductAffiliate.where(affiliate:, product:).count).to eq(1)
    end

    it "lets an assignment deadlock roll back the caller transaction" do
      seller = create(:user)
      affiliates = create_list(:direct_affiliate, 2, seller:, apply_to_all_products: true)
      product = create(:product, user: seller, draft: true)
      assignment_count = 0
      allow(ProductAffiliate).to receive(:create_if_missing!).and_wrap_original do |method, **attributes|
        assignment_count += 1
        raise ActiveRecord::Deadlocked if assignment_count == 2

        method.call(**attributes)
      end
      expect(AffiliateMailer).not_to receive(:notify_direct_affiliate_of_new_product)

      expect do
        ActiveRecord::Base.transaction { product.publish! }
      end.to raise_error(ActiveRecord::Deadlocked)

      expect(product.reload).not_to be_published
      expect(ProductAffiliate.where(affiliate: affiliates, product:)).to be_empty
      expect(assignment_count).to eq(2)
    end
  end

  describe "default offer code validation" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller, price_cents: 2000) }

    it "allows a discount code that applies to the product" do
      offer_code = create(:offer_code, user: seller, products: [product])

      expect(product.update(default_offer_code_id: offer_code.id)).to eq(true)
      expect(product.reload.default_offer_code_id).to eq(offer_code.id)
    end

    it "disallows an upsell's codeless discount" do
      upsell = create(:upsell, seller:, product:)
      upsell.build_offer_code(user: seller, products: [product], amount_percentage: 10, amount_cents: nil)
      upsell.save!

      expect(product.update(default_offer_code_id: upsell.offer_code.id)).to eq(false)
      expect(product.errors.full_messages).to include("Default offer code must belong to your offer codes")
      expect(product.reload.default_offer_code_id).to be_nil
    end
  end

  describe "repairing detached defaults after concurrent edits" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller, price_cents: 2000) }
    let(:other_product) { create(:product, user: seller) }

    it "clears a default whose code was detached before the assignment committed" do
      offer_code = create(:offer_code, user: seller, products: [product, other_product])
      offer_code.products.delete(product)
      # The assignment's validation read the join table before the concurrent
      # edit landed; skip it to reproduce that stale read.
      allow_any_instance_of(Link).to receive(:default_offer_code_must_be_valid)

      product.update!(default_offer_code_id: offer_code.id)

      expect(product.reload.default_offer_code_id).to be_nil
    end

    it "repairs even when a later save in the same transaction overwrites saved_changes" do
      offer_code = create(:offer_code, user: seller, products: [product, other_product])
      offer_code.products.delete(product)
      allow_any_instance_of(Link).to receive(:default_offer_code_must_be_valid)

      Link.transaction do
        product.update!(default_offer_code_id: offer_code.id)
        product.update!(name: "Renamed")
      end

      expect(product.reload.default_offer_code_id).to be_nil
    end

    it "leaves the default alone when the code is reattached before the clearing write" do
      offer_code = create(:offer_code, user: seller, products: [product, other_product])
      offer_code.products.delete(product)
      allow_any_instance_of(Link).to receive(:default_offer_code_must_be_valid)
      product.update_column(:default_offer_code_id, offer_code.id)

      # Stand in for a concurrent request re-adding the product after this repair
      # decided the default was detached but before its UPDATE lands.
      allow(Link).to receive(:where).and_wrap_original do |original, *args|
        offer_code.products << product unless offer_code.products.reload.include?(product)
        original.call(*args)
      end

      product.send(:repair_detached_default_offer_code)

      expect(product.reload.default_offer_code_id).to eq(offer_code.id)
    end
  end

  describe "clearing detached default discounts on undelete" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller, price_cents: 2000) }

    it "clears a default discount that detached while the product was deleted" do
      offer_code = create(:offer_code, user: seller, products: [product])
      product.update!(default_offer_code_id: offer_code.id)
      product.update!(deleted_at: Time.current)
      offer_code.products.delete(product)

      product.update!(deleted_at: nil)

      expect(product.reload.default_offer_code_id).to be_nil
    end

    it "keeps a default discount that still applies" do
      offer_code = create(:offer_code, user: seller, products: [product])
      product.update!(default_offer_code_id: offer_code.id)
      product.update!(deleted_at: Time.current)

      product.update!(deleted_at: nil)

      expect(product.reload.default_offer_code_id).to eq(offer_code.id)
    end

    it "keeps a valid default another request assigned while this undelete was in flight" do
      detached = create(:offer_code, user: seller, products: [product])
      product.update!(default_offer_code_id: detached.id)
      product.update!(deleted_at: Time.current)
      detached.products.delete(product)
      replacement = create(:offer_code, user: seller, products: [product], amount_cents: 300)

      # Stand in for a concurrent request assigning a valid default after this
      # save decided the old one was detached but before the clearing write lands.
      # Injected at the UPDATE itself, so a repair that reads through the scope and
      # then writes blindly is still caught.
      allow_any_instance_of(ActiveRecord::Relation).to receive(:update_all).and_wrap_original do |original, *args|
        Link.connection.update(
          Link.sanitize_sql(["UPDATE links SET default_offer_code_id = ? WHERE id = ?", replacement.id, product.id])
        )
        original.call(*args)
      end

      product.update!(deleted_at: nil)

      expect(product.reload.default_offer_code_id).to eq(replacement.id)
    end

    it "leaves the in-memory product agreeing with the cleared row" do
      offer_code = create(:offer_code, user: seller, products: [product])
      product.update!(default_offer_code_id: offer_code.id)
      product.update!(deleted_at: Time.current)
      offer_code.products.delete(product)

      product.update!(deleted_at: nil)

      expect(product.default_offer_code_id).to be_nil
      expect(product.default_offer_code).to be_nil
      expect(product.changed?).to eq(false)
    end
  end
end
