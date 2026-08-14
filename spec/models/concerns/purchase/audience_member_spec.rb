# frozen_string_literal: true

require "spec_helper"

RSpec.describe Purchase::AudienceMember, defer_audience_refresh: true do
  let(:seller) { create(:user) }
  let(:product) { create(:membership_product, user: seller) }

  def audience_member_for(purchase)
    AudienceMember.find_by(email: purchase.email, seller_id: seller.id)
  end

  # The projection is rebuilt out of band. Specs drain the queued refreshes to observe the
  # converged state.
  def drain_audience_refreshes
    jobs = RefreshAudienceMemberJob.jobs.dup
    RefreshAudienceMemberJob.clear
    jobs.map { _1["args"] }.uniq.each { RefreshAudienceMemberJob.new.perform(*_1) }
  end

  describe "scheduling" do
    it "schedules a refresh when a purchase is created" do
      purchase = create(:purchase, link: create(:product, user: seller), seller:)

      expect(RefreshAudienceMemberJob).to have_enqueued_sidekiq_job(purchase.email, seller.id)

      drain_audience_refreshes
      member = audience_member_for(purchase)
      expect(member).to be_present
      expect(member.details["purchases"].map { _1["id"] }).to eq([purchase.id])
    end

    it "does not schedule a refresh for saves that cannot affect the audience" do
      purchase = create(:purchase, link: create(:product, user: seller), seller:)
      drain_audience_refreshes

      purchase.reload.update!(referrer: "https://example.com")

      expect(RefreshAudienceMemberJob.jobs).to be_empty
    end

    it "schedules a refresh when a watched change is followed by an unwatched save in one transaction" do
      purchase = create(:purchase, link: create(:product, user: seller), seller:)
      drain_audience_refreshes
      RefreshAudienceMemberJob.clear

      Purchase.transaction do
        purchase.update!(can_contact: false)
        purchase.update!(referrer: "https://example.com")
      end

      expect(RefreshAudienceMemberJob).to have_enqueued_sidekiq_job(purchase.email, seller.id)
    end

    it "refreshes the old email when an email change is followed by another save in one transaction" do
      purchase = create(:purchase, link: create(:product, user: seller), seller:)
      drain_audience_refreshes
      old_email = purchase.email
      RefreshAudienceMemberJob.clear

      Purchase.transaction do
        purchase.update!(email: "new-address@example.com")
        purchase.update!(referrer: "https://example.com")
      end

      expect(RefreshAudienceMemberJob).to have_enqueued_sidekiq_job(old_email, seller.id)
      expect(RefreshAudienceMemberJob).to have_enqueued_sidekiq_job("new-address@example.com", seller.id)
    end

    it "schedules refreshes for both emails when the purchase email changes" do
      purchase = create(:purchase, link: create(:product, user: seller), seller:)
      drain_audience_refreshes
      old_email = purchase.email

      purchase.reload.update!(email: "new-address@example.com")

      expect(RefreshAudienceMemberJob).to have_enqueued_sidekiq_job(old_email, seller.id)
      expect(RefreshAudienceMemberJob).to have_enqueued_sidekiq_job("new-address@example.com", seller.id)

      drain_audience_refreshes
      old_member = AudienceMember.find_by(email: old_email, seller:)
      expect(old_member).to be_present
      expect(old_member.deleted_at).to be_present
      expect(AudienceMember.find_by(email: "new-address@example.com", seller:)).to be_present
    end

    it "schedules a refresh when a purchase is destroyed" do
      purchase = create(:purchase, link: create(:product, user: seller), seller:)
      drain_audience_refreshes
      expect(audience_member_for(purchase)).to be_present

      purchase.destroy!
      drain_audience_refreshes

      member = audience_member_for(purchase)
      expect(member).to be_present
      expect(member.deleted_at).to be_present
    end
  end

  describe "re-subscribing after an unsubscribe" do
    let!(:original_purchase) { create(:membership_purchase, link: product, seller:) }

    before { drain_audience_refreshes }

    it "soft-deletes the audience row on unsubscribe instead of destroying it, and restores it on re-subscribe" do
      expect(audience_member_for(original_purchase)).to be_present

      original_purchase.unsubscribe_buyer
      drain_audience_refreshes
      member = audience_member_for(original_purchase)
      expect(member).to be_present
      expect(member.deleted_at).to be_present
      expect(member.details).to eq({})

      original_purchase.reload.update!(can_contact: true)
      drain_audience_refreshes

      member = audience_member_for(original_purchase)
      expect(member).to be_present
      expect(member.deleted_at).to be_nil
      expect(member.details["purchases"].map { _1["id"] }).to include(original_purchase.id)
      expect(member.customer).to be(true)
    end

    it "puts the buyer back in the seller's audience filter results" do
      original_purchase.unsubscribe_buyer
      drain_audience_refreshes
      expect(AudienceMember.filter(seller_id: seller.id, params: { bought_product_ids: [product.id] })).to be_empty

      original_purchase.reload.update!(can_contact: true)
      drain_audience_refreshes

      expect(AudienceMember.filter(seller_id: seller.id, params: { bought_product_ids: [product.id] }).map(&:email))
        .to eq([original_purchase.email])
    end

    it "recovers the original purchase when a renewal charge is the row being re-subscribed" do
      renewal = create(:membership_purchase, link: product, seller:, email: original_purchase.email,
                                             subscription: original_purchase.subscription,
                                             is_original_subscription_purchase: false)
      renewal.update!(can_contact: false)
      drain_audience_refreshes
      # The mixed state seen in production: the original purchase reads as contactable, so a
      # spot-check looks fine, but its audience row was soft-deleted while it was unsubscribed and
      # nothing ever saved that purchase again to restore it.
      audience_member_for(original_purchase).soft_delete!
      expect(original_purchase.reload.can_contact?).to be(true)

      # A renewal charge is never an audience member in its own right, but the refresh rebuilds
      # the whole row from live state, so the original purchase comes back with it.
      expect(renewal.reload.should_be_audience_member?).to be(false)
      renewal.update!(can_contact: true)
      drain_audience_refreshes

      member = audience_member_for(original_purchase)
      expect(member).to be_present
      expect(member.details["purchases"].map { _1["id"] }).to eq([original_purchase.id])
    end

    it "does not resurrect a row for a buyer who is still unsubscribed" do
      original_purchase.unsubscribe_buyer
      drain_audience_refreshes

      # Save a change to another attribute the callback watches, with can_contact still false.
      original_purchase.reload.update!(is_access_revoked: true)
      drain_audience_refreshes

      expect(original_purchase.reload.can_contact?).to be(false)
      expect(audience_member_for(original_purchase)).to be_present
      expect(audience_member_for(original_purchase).deleted_at).to be_present
      expect(AudienceMember.filter(seller_id: seller.id, params: { bought_product_ids: [product.id] })).to be_empty
    end

    it "restores a soft-deleted row when support bypasses callbacks to re-enable its purchase" do
      original_purchase.unsubscribe_buyer
      drain_audience_refreshes
      expect(audience_member_for(original_purchase)).to have_attributes(deleted_at: be_present, details: {})

      original_purchase.reload.update_columns(can_contact: true)

      expect(audience_member_for(original_purchase).deleted_at).to be_nil
      expect(AudienceMember.filter(seller_id: seller.id, params: { bought_product_ids: [product.id] }).map(&:email))
        .to eq([original_purchase.email])
    end

    it "rolls back a callback-free re-enable when the audience rebuild fails" do
      original_purchase.unsubscribe_buyer
      drain_audience_refreshes
      allow_any_instance_of(AudienceMember).to receive(:refresh!).and_raise("audience rebuild failed")

      expect do
        original_purchase.reload.update_columns(can_contact: true)
      end.to raise_error("audience rebuild failed")

      expect(original_purchase.reload.can_contact?).to be(false)
      expect(audience_member_for(original_purchase).deleted_at).to be_present
    end

    it "restores purchase details when another audience source kept the row active" do
      affiliate_user = create(:affiliate_user, email: original_purchase.email)
      affiliate = create(:direct_affiliate, affiliate_user:, seller:)
      create(:product_affiliate, product:, affiliate:, affiliate_basis_points: 10_00)
      original_purchase.unsubscribe_buyer
      drain_audience_refreshes
      member = audience_member_for(original_purchase)
      expect(member).to have_attributes(deleted_at: nil, customer: false, affiliate: true)

      original_purchase.reload.update_columns(can_contact: true)

      expect(member.reload).to have_attributes(deleted_at: nil, customer: true, affiliate: true)
      expect(member.details["purchases"].map { _1["id"] }).to include(original_purchase.id)
    end
  end

  describe "a new purchase for a buyer who unsubscribed" do
    it "stays uncontactable for one-off purchases" do
      first = create(:purchase, link: create(:product, user: seller), seller:)
      first.unsubscribe_buyer
      drain_audience_refreshes

      second = create(:purchase, link: create(:product, user: seller), seller:, email: first.email)
      drain_audience_refreshes

      expect(second.can_contact?).to be(false)
      expect(audience_member_for(first)).to be_present
      expect(audience_member_for(first).deleted_at).to be_present
    end

    it "stays contactable when the subscription's original purchase is contactable again" do
      original_purchase = create(:membership_purchase, link: product, seller:)
      stale_sibling = create(:purchase, link: create(:product, user: seller), seller:, email: original_purchase.email)

      original_purchase.unsubscribe_buyer
      # Re-subscribe only the subscription itself, leaving the unrelated older purchase
      # marked uncontactable — the mixed state that used to re-break the buyer on renewal.
      original_purchase.reload.update!(can_contact: true)
      expect(stale_sibling.reload.can_contact?).to be(false)

      renewal = create(:membership_purchase, link: product, seller:, email: original_purchase.email,
                                             subscription: original_purchase.subscription,
                                             is_original_subscription_purchase: false)
      drain_audience_refreshes

      expect(renewal.can_contact?).to be(true)
      member = audience_member_for(original_purchase)
      expect(member.details["purchases"].map { _1["id"] }).to include(original_purchase.id)
    end
  end

  describe "RefreshAudienceMemberJob" do
    it "removes a row whose buyer no longer qualifies" do
      purchase = create(:purchase, link: create(:product, user: seller), seller:)
      drain_audience_refreshes
      expect(audience_member_for(purchase)).to be_present

      purchase.update_columns(stripe_refunded: true)
      RefreshAudienceMemberJob.new.perform(purchase.email, seller.id)

      member = audience_member_for(purchase)
      expect(member).to be_present
      expect(member.deleted_at).to be_present
    end

    it "rebuilds from live source state taken after locking the projection row" do
      purchase = create(:purchase, link: create(:product, user: seller), seller:)
      drain_audience_refreshes
      expect(audience_member_for(purchase)).to be_present

      allow_any_instance_of(AudienceMember).to receive(:lock!).and_wrap_original do |orig|
        purchase.update_columns(stripe_refunded: true)
        orig.call
      end

      RefreshAudienceMemberJob.new.perform(purchase.email, seller.id)

      member = audience_member_for(purchase)
      expect(member).to be_present
      expect(member.deleted_at).to be_present
    end

    it "holds the projection lock through the rebuild via with_lock" do
      purchase = create(:purchase, link: create(:product, user: seller), seller:)
      drain_audience_refreshes
      expect(audience_member_for(purchase)).to be_present

      held = false
      allow_any_instance_of(AudienceMember).to receive(:with_lock).and_wrap_original do |orig, &block|
        held = true
        orig.call(&block)
      end

      RefreshAudienceMemberJob.new.perform(purchase.email, seller.id)

      expect(held).to be(true)
    end

    it "is a no-op for an email with no qualifying records and no existing row" do
      expect do
        RefreshAudienceMemberJob.new.perform("nobody@example.com", seller.id)
      end.not_to change(AudienceMember, :count)
    end

    it "persists a tombstone when the first refresh sees only uncontactable sources" do
      purchase = create(:purchase, link: create(:product, user: seller), seller:)
      purchase.update_columns(can_contact: false)
      RefreshAudienceMemberJob.clear

      expect do
        RefreshAudienceMemberJob.new.perform(purchase.email, seller.id)
      end.to change(AudienceMember, :count).by(1)

      member = audience_member_for(purchase)
      expect(member.deleted_at).to be_present
      expect(member.details).to eq({})
    end

    it "does not persist a tombstone for an in-progress purchase" do
      purchase = create(:purchase_in_progress, link: create(:product, user: seller), seller:)
      RefreshAudienceMemberJob.clear

      expect do
        RefreshAudienceMemberJob.new.perform(purchase.email, seller.id)
      end.not_to change(AudienceMember, :count)
    end

    it "locks only until execution so a mid-run change can enqueue a follow-up" do
      expect(RefreshAudienceMemberJob.get_sidekiq_options["lock"]).to eq(:until_executing)
      expect(RefreshAudienceMemberJob.get_sidekiq_options).not_to have_key("on_conflict")
    end

    it "does not enqueue a refresh for a rolled-back purchase" do
      expect do
        Purchase.transaction do
          create(:purchase, link: create(:product, user: seller), seller:)
          raise ActiveRecord::Rollback
        end
      end.not_to change { RefreshAudienceMemberJob.jobs.size }
    end

    # Direct callers (e.g. Subscription#deactivate!) invoke schedule_audience_member_refresh
    # mid-transaction. Enqueueing right there lets the job race the commit and rebuild from
    # pre-commit state, so the enqueue must be deferred to the transaction's commit.
    it "defers a mid-transaction schedule call until the transaction commits" do
      purchase = create(:purchase, link: create(:product, user: seller), seller:)
      RefreshAudienceMemberJob.clear

      Purchase.transaction do
        purchase.schedule_audience_member_refresh
        expect(RefreshAudienceMemberJob.jobs).to be_empty
      end

      expect(RefreshAudienceMemberJob).to have_enqueued_sidekiq_job(purchase.email, seller.id)
    end

    it "drops a mid-transaction schedule call when the transaction rolls back" do
      purchase = create(:purchase, link: create(:product, user: seller), seller:)
      RefreshAudienceMemberJob.clear

      Purchase.transaction do
        purchase.schedule_audience_member_refresh
        raise ActiveRecord::Rollback
      end

      expect(RefreshAudienceMemberJob.jobs).to be_empty
    end

    it "enqueues a follow-up refresh when the buyer changes while a refresh is running" do
      purchase = create(:purchase, link: create(:product, user: seller), seller:)
      RefreshAudienceMemberJob.clear

      allow(AudienceMember).to receive(:find_or_initialize_by).and_wrap_original do |orig, **kwargs|
        purchase.update!(can_contact: false)
        orig.call(**kwargs)
      end

      RefreshAudienceMemberJob.new.perform(purchase.email, seller.id)

      expect(RefreshAudienceMemberJob).to have_enqueued_sidekiq_job(purchase.email, seller.id)
    end
  end
end
