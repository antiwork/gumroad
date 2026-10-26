# frozen_string_literal: true

require "spec_helper"

describe Link, "sales hold" do
  let(:admin) { create(:admin_user) }
  let(:seller) { create(:user, email: "seller@example.com") }
  let(:product) { create(:product, user: seller, price_cents: 1_00) }

  def hold!(listing = product)
    listing.hold_sales!(seller: listing.user, held_by: admin)
  end

  def publish_error(listing)
    listing.publish!
    nil
  rescue Link::LinkInvalid => e
    e.message
  end

  def new_purchase(listing, **attributes)
    build(:purchase, link: listing, seller: listing.user, email: "buyer@example.com", price_cents: listing.price_cents, **attributes)
  end

  describe "#hold_sales!" do
    it "takes a live listing off sale and records that the hold did it" do
      hold, created = hold!

      expect(created).to be(true)
      expect(hold).to have_attributes(product:, held_by: admin, unpublished_listing: true, released_at: nil)
      expect(product.reload).not_to be_alive
      expect(product).not_to be_is_unpublished_by_admin
      expect(product.active_sales_hold).to eq(hold)
    end

    it "refuses new paid and free purchases" do
      free_product = create(:product, user: seller, price_cents: 0)
      hold!
      hold!(free_product)

      [product, free_product].each do |listing|
        purchase = new_purchase(listing.reload)
        purchase.save
        expect(purchase.error_code).to eq(PurchaseErrorCode::NOT_FOR_SALE)
        expect(purchase.errors.full_messages).to include("This product is not currently for sale.")
      end
    end

    it "lets the same purchase past the sale check when the listing is not held" do
      purchase = new_purchase(product)
      purchase.save

      expect(purchase.error_code).not_to eq(PurchaseErrorCode::NOT_FOR_SALE)
      expect(purchase.errors.full_messages).not_to include("This product is not currently for sale.")
    end

    it "returns the existing hold instead of placing a second one" do
      first, = hold!

      second, created = hold!(Link.find(product.id))

      expect(created).to be(false)
      expect(second).to eq(first)
      expect(product.sales_holds.count).to eq(1)
    end

    it "writes nothing for a seller who does not own the listing" do
      other_seller = create(:user, email: "other-seller@example.com")

      expect { product.hold_sales!(seller: other_seller, held_by: admin) }.to raise_error(Link::SalesHoldSellerChanged)

      expect(product.reload).to be_alive
      expect(product.sales_holds).to be_empty
    end

    it "keeps a listing the seller already unpublished as it was" do
      unpublished_at = 3.days.ago.change(usec: 0)
      product.update!(purchase_disabled_at: unpublished_at)

      hold, = hold!

      expect(hold.unpublished_listing).to be(false)
      expect(product.reload.purchase_disabled_at).to eq(unpublished_at)
    end

    it "leaves deletion, ban and draft state as they are" do
      deleted = create(:product, user: seller, deleted_at: 1.day.ago)
      banned = create(:product, user: seller, banned_at: 1.day.ago)
      draft = create(:product, user: seller, draft: true)

      [deleted, banned, draft].each { hold!(_1) }

      expect(deleted.reload.deleted_at).to be_present
      expect(banned.reload.banned_at).to be_present
      expect(draft.reload).to be_draft
      [deleted, banned, draft].each { expect(_1.purchase_disabled_at).to be_present }
    end

    it "leaves the account, its watch, other listings, and the listing's files, content, domain and profile placement alone" do
      other_product = create(:product, user: seller)
      watch = create(:watched_user, user: seller, revenue_threshold_cents: 100_00)
      file = create(:readable_document, link: product)
      rich_content = create(:product_rich_content, entity: product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Chapter one" }] }])
      custom_domain = create(:custom_domain, :with_product, product:, domain: "listing.example.com")
      section = create(:seller_profile_products_section, seller:, shown_products: [product.id])
      risk_state = seller.reload.user_risk_state
      comments_count = seller.comments.count

      hold!

      expect(seller.reload.user_risk_state).to eq(risk_state)
      expect(seller.comments.count).to eq(comments_count)
      expect(watch.reload).to be_alive
      expect(watch.revenue_threshold_cents).to eq(100_00)
      expect(other_product.reload).to be_alive
      expect(file.reload).to be_alive
      expect(rich_content.reload).to be_alive
      expect(custom_domain.reload).to be_alive
      expect(section.reload.shown_products).to eq([product.id])
      expect(product.reload.deleted_at).to be_nil
    end

    it "keeps existing buyers' access and memberships" do
      purchase = create(:purchase, link: product, seller:, email: "buyer@example.com")
      url_redirect = create(:url_redirect, purchase:, link: product)
      membership_purchase = create(:membership_purchase, link: create(:membership_product, user: seller), seller:, email: "member@example.com")
      subscription = membership_purchase.subscription

      hold!
      hold!(membership_purchase.link)

      expect(purchase.reload).to be_successful
      expect(url_redirect.reload.purchase).to eq(purchase)
      expect(subscription.reload).to be_alive
      expect(CancelSubscriptionsForProductWorker.jobs.size).to eq(0)
    end

    it "does not email the seller" do
      expect { hold! }.not_to have_enqueued_mail
    end
  end

  describe "#release_sales_hold!" do
    it "lifts the hold without relisting, and the seller can publish again" do
      hold, = hold!

      expect(product.release_sales_hold!(hold, seller:, released_by: admin)).to be(true)

      expect(hold.reload).to have_attributes(released_by: admin, active?: false)
      expect(product.reload).not_to be_alive
      expect(publish_error(product)).to be_nil
      expect(product.reload).to be_published
    end

    it "does nothing for a hold that was already released, and keeps a newer one" do
      old_hold, = hold!
      product.release_sales_hold!(old_hold, seller:, released_by: admin)
      new_hold, = hold!(product.reload)

      expect(product.release_sales_hold!(old_hold, seller:, released_by: admin)).to be(false)

      expect(new_hold.reload).to be_active
      expect(publish_error(product.reload)).to eq(Link::UNPUBLISHED_BY_ADMIN_MESSAGE)
    end

    it "leaves another admin takedown in place" do
      hold, = hold!
      product.reload.unpublish!(is_unpublished_by_admin: true)

      product.release_sales_hold!(hold, seller:, released_by: admin)

      expect(product.reload).to be_is_unpublished_by_admin
      expect(publish_error(product)).to eq(Link::UNPUBLISHED_BY_ADMIN_MESSAGE)
    end

    it "does not undelete a listing the seller deleted while it was held" do
      hold, = hold!
      product.reload.delete!

      product.release_sales_hold!(hold, seller:, released_by: admin)

      expect(product.reload.deleted_at).to be_present
      expect(product.purchase_disabled_at).to be_present
    end
  end

  describe "seller publishing while held" do
    it "is refused, including through the admin re-enable path" do
      hold!

      expect(publish_error(product.reload)).to eq(Link::UNPUBLISHED_BY_ADMIN_MESSAGE)
      expect(product.errors.full_messages).to eq([Link::UNPUBLISHED_BY_ADMIN_MESSAGE])
      expect { Link.find(product.id).publish_by_admin! }.to raise_error(Link::LinkInvalid, Link::UNPUBLISHED_BY_ADMIN_MESSAGE)
      expect(product.reload).not_to be_alive
    end

    it "is refused for a copy of the unpublished listing loaded before the hold" do
      product.unpublish!
      stale = Link.find(product.id)
      hold!(product.reload)

      expect(publish_error(stale)).to eq(Link::UNPUBLISHED_BY_ADMIN_MESSAGE)
      expect(product.reload.purchase_disabled_at).to be_present
    end

    it "is refused for a held listing the seller deleted" do
      hold!
      product.reload.delete!

      expect(publish_error(Link.find(product.id))).to eq(Link::UNPUBLISHED_BY_ADMIN_MESSAGE)
      expect(product.reload.deleted_at).to be_present
    end

    it "survives a stale save of an unrelated flag" do
      stale = Link.find(product.id)
      hold!

      stale.is_duplicating = true
      stale.save!(validate: false)

      expect(product.reload.active_sales_hold).to be_present
      expect(publish_error(product)).to eq(Link::UNPUBLISHED_BY_ADMIN_MESSAGE)
    end

    it "stays off sale through archive, unarchive and undelete, including from copies loaded before the hold" do
      stale = Link.find(product.id)
      hold!

      stale.update!(archived: true, purchase_disabled_at: stale.purchase_disabled_at || Time.current)
      Link.find(product.id).update!(archived: false)
      Link.find(product.id).delete!
      Link.find(product.id).mark_undeleted!

      expect(product.reload).not_to be_alive
      expect(product.active_sales_hold).to be_present
      expect(publish_error(product)).to eq(Link::UNPUBLISHED_BY_ADMIN_MESSAGE)
    end

    it "keeps the hold when the account is suspended and restored" do
      hold!
      seller.flag_for_fraud!(author_id: admin.id)
      seller.suspend_for_fraud!(author_id: admin.id)
      expect(product.reload.banned_at).to be_present

      seller.reload.mark_compliant!(author_id: admin.id, clear_suspension: true)

      expect(product.reload.banned_at).to be_nil
      expect(product).not_to be_alive
      expect(product.active_sales_hold).to be_present
      expect(publish_error(product)).to eq(Link::UNPUBLISHED_BY_ADMIN_MESSAGE)
    end
  end

  describe "an admin takedown committed after the seller's copy loaded" do
    it "refuses the publish" do
      product.unpublish!
      stale = Link.find(product.id)
      Link.find(product.id).unpublish!(is_unpublished_by_admin: true)

      expect(publish_error(stale)).to eq(Link::UNPUBLISHED_BY_ADMIN_MESSAGE)
      expect(product.reload.purchase_disabled_at).to be_present
    end

    it "still lets the admin re-enable path clear its own marker" do
      product.unpublish!(is_unpublished_by_admin: true)

      Link.find(product.id).publish_by_admin!

      expect(product.reload).to be_published
      expect(product).not_to be_is_unpublished_by_admin
    end
  end
end
