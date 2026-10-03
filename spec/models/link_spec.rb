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

  describe "custom permalink uniqueness" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }

    it "lets a product take the unique permalink of the seller's deleted product" do
      deleted = create(:product, user: seller, deleted_at: Time.current)

      product.custom_permalink = deleted.unique_permalink

      expect(product).to be_valid
      expect(product.save).to eq(true)
    end

    it "rejects the unique permalink of another alive product of the seller" do
      other = create(:product, user: seller)

      product.custom_permalink = other.unique_permalink

      expect(product).not_to be_valid
      expect(product.errors[:custom_permalink]).to eq(["is already used by another one of your products"])
    end

    it "rejects the unique permalink of an unpublished product, which still resolves" do
      unpublished = create(:product, user: seller, purchase_disabled_at: Time.current)

      product.custom_permalink = unpublished.unique_permalink

      expect(product).not_to be_valid
      expect(product.errors[:custom_permalink]).to eq(["is already used by another one of your products"])
    end

    it "rejects the unique permalink of another alive product on a new product" do
      other = create(:product, user: seller)

      new_product = build(:product, user: seller, custom_permalink: other.unique_permalink)

      expect(new_product).not_to be_valid
      expect(new_product.errors[:custom_permalink]).to eq(["is already used by another one of your products"])
    end

    it "does not affect another seller's products" do
      other_seller_product = create(:product, user: create(:user))

      product.custom_permalink = other_seller_product.unique_permalink

      expect(product).to be_valid
    end

    it "serves the live product on the reused slug and refuses to restore the deleted one" do
      deleted = create(:product, user: seller, deleted_at: Time.current)
      product.update!(custom_permalink: deleted.unique_permalink)

      expect(Link.fetch_leniently(deleted.unique_permalink, user: seller)).to eq(product)

      expect(deleted.update(deleted_at: nil)).to eq(false)
      expect(deleted.errors[:base]).to eq(["Can't restore this product: another one of your products already uses its URL as a custom permalink"])
      expect(deleted.reload).to be_deleted
      expect(Link.fetch_leniently(deleted.unique_permalink, user: seller)).to eq(product)
    end

    it "refuses to restore a deleted product whose URL an unpublished product uses" do
      deleted = create(:product, user: seller, deleted_at: Time.current)
      product.update!(custom_permalink: deleted.unique_permalink)
      product.unpublish!

      expect(deleted.update(deleted_at: nil)).to eq(false)
      expect(deleted.reload).to be_deleted
    end

    it "restores a deleted product once nothing else uses its unique permalink" do
      deleted = create(:product, user: seller, deleted_at: Time.current)
      product.update!(custom_permalink: deleted.unique_permalink)
      product.update!(custom_permalink: "renamed")

      expect(deleted.update(deleted_at: nil)).to eq(true)
      expect(Link.fetch_leniently(deleted.unique_permalink, user: seller)).to eq(deleted)
    end

    it "locks the seller before the profile row when a save that claims a permalink shows the product in sections" do
      seller.seller_profile.save!
      product.custom_permalink = "claimed-slug"
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql].to_s }

      begin
        ActiveRecord::Base.transaction { product.show_in_sections!([]) }
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      seller_lock = statements.index { _1.include?("FROM `users`") && _1.include?("FOR UPDATE") }
      profile_lock = statements.index { _1.include?("FROM `seller_profiles`") && _1.include?("FOR UPDATE") }
      expect(seller_lock).to be_present
      expect(profile_lock).to be_present
      expect(seller_lock).to be < profile_lock
    end

    it "locks the seller first when a stale copy repeats a permalink that has since changed in storage" do
      product.update!(custom_permalink: "first-slug")
      stale = Link.find(product.id)
      Link.where(id: product.id).update_all(custom_permalink: "second-slug")
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql].to_s }

      begin
        Link.transaction { stale.lock_for_permalink_claim!("first-slug") }
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      seller_lock = statements.index { _1.include?("FROM `users`") && _1.include?("FOR UPDATE") }
      product_lock = statements.index { _1.include?("FROM `links`") && _1.include?("FOR UPDATE") }
      expect(seller_lock).to be_present
      expect(seller_lock).to be < product_lock
    end

    it "fails the lock rather than take the seller row after the product row when the permalink moves during the lock" do
      product.update!(custom_permalink: "first-slug")
      stale = Link.find(product.id)
      allow(stale).to receive(:lock!).and_wrap_original do |original, *args|
        Link.where(id: product.id).update_all(custom_permalink: "second-slug")
        original.call(*args)
      end

      expect { Link.transaction { stale.lock_for_permalink_claim!("first-slug") } }.to raise_error(Link::PermalinkChangedDuringLock)
    end

    it "keeps the permalink checks' locking reads on the seller's own rows" do
      deleted = create(:product, user: seller, deleted_at: Time.current)
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql].to_s }

      begin
        product.update!(custom_permalink: "claimed-slug")
        Link.find(deleted.id).update!(deleted_at: nil)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      permalink_reads = statements.select { _1.include?("FROM `links`") && _1.include?("FOR UPDATE") && _1.include?("permalink` =") }
      expect(permalink_reads.size).to be >= 3
      expect(permalink_reads).to all(include("INDEX(links index_links_on_user_id)"))
    end

    it "locks the seller before the product row when publishing restores a deleted product" do
      deleted = create(:product, user: seller, deleted_at: Time.current)
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql].to_s }

      begin
        Link.find(deleted.id).publish!
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      seller_lock = statements.index { _1.include?("FROM `users`") && _1.include?("FOR UPDATE") }
      product_lock = statements.index { _1.include?("FROM `links`") && _1.include?("FOR UPDATE") }
      expect(seller_lock).to be_present
      expect(product_lock).to be_present
      expect(seller_lock).to be < product_lock
      expect(deleted.reload).not_to be_deleted
    end

    it "restores a deleted product that has no conflict" do
      deleted = create(:product, user: seller, deleted_at: Time.current)

      expect(deleted.update(deleted_at: nil)).to eq(true)
    end
  end

  describe "#plaintext_description" do
    def description_for(html)
      create(:product, description: html).plaintext_description
    end

    # Block elements carry no whitespace of their own, so stripping the tags used to fuse
    # "</h2><p>" into "What you getA 25-page guide" in every meta/OG/feed description.
    it "separates a heading from the paragraph after it" do
      expect(description_for("<h2>What you get</h2><p>A 25-page guide</p>"))
        .to eq("What you get A 25-page guide")
    end

    it "separates list items" do
      expect(description_for("<ul><li>One</li><li>Two</li></ul>")).to eq("One Two")
    end

    it "decodes entities so callers get real text rather than escaped text" do
      expect(description_for("<p>Fish &amp; Chips &mdash; 100% caf&eacute;</p>"))
        .to eq("Fish & Chips — 100% café")
    end

    it "collapses the separators it inserts around inline markup" do
      expect(description_for("<p>A <strong>bold</strong> word</p>")).to eq("A bold word")
    end

    it "returns an empty string when there is no description" do
      expect(description_for(nil)).to eq("")
      expect(description_for("   ")).to eq("")
    end

    it "returns an empty string for a markup-only description" do
      expect(description_for("<p><br></p>")).to eq("")
    end
  end
end
