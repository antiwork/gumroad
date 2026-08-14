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

    it "schedules refreshes for both emails when the purchase email changes" do
      purchase = create(:purchase, link: create(:product, user: seller), seller:)
      drain_audience_refreshes
      old_email = purchase.email

      purchase.reload.update!(email: "new-address@example.com")

      expect(RefreshAudienceMemberJob).to have_enqueued_sidekiq_job(old_email, seller.id)
      expect(RefreshAudienceMemberJob).to have_enqueued_sidekiq_job("new-address@example.com", seller.id)

      drain_audience_refreshes
      expect(AudienceMember.find_by(email: old_email, seller:)).to be_nil
      expect(AudienceMember.find_by(email: "new-address@example.com", seller:)).to be_present
    end

    it "schedules a refresh when a purchase is destroyed" do
      purchase = create(:purchase, link: create(:product, user: seller), seller:)
      drain_audience_refreshes
      expect(audience_member_for(purchase)).to be_present

      purchase.destroy!
      drain_audience_refreshes

      expect(audience_member_for(purchase)).to be_nil
    end
  end

  describe "re-subscribing after an unsubscribe" do
    let!(:original_purchase) { create(:membership_purchase, link: product, seller:) }

    before { drain_audience_refreshes }

    it "rebuilds the audience member row that unsubscribing destroyed" do
      expect(audience_member_for(original_purchase)).to be_present

      original_purchase.unsubscribe_buyer
      drain_audience_refreshes
      expect(audience_member_for(original_purchase)).to be_nil

      original_purchase.reload.update!(can_contact: true)
      drain_audience_refreshes

      member = audience_member_for(original_purchase)
      expect(member).to be_present
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
      # spot-check looks fine, but its audience row was destroyed while it was unsubscribed and
      # nothing ever rebuilt it.
      audience_member_for(original_purchase)&.destroy!
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
      expect(audience_member_for(original_purchase)).to be_nil
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
      expect(audience_member_for(first)).to be_nil
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

      expect(audience_member_for(purchase)).to be_nil
    end

    it "is a no-op for an email with no qualifying records and no existing row" do
      expect do
        RefreshAudienceMemberJob.new.perform("nobody@example.com", seller.id)
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
