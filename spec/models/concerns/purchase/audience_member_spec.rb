# frozen_string_literal: true

require "spec_helper"

RSpec.describe Purchase::AudienceMember do
  let(:seller) { create(:user) }
  let(:product) { create(:membership_product, user: seller) }

  def audience_member_for(purchase)
    AudienceMember.find_by(email: purchase.email, seller_id: seller.id)
  end

  describe "re-subscribing after an unsubscribe" do
    let!(:original_purchase) { create(:membership_purchase, link: product, seller:) }

    it "rebuilds the audience member row that unsubscribing destroyed" do
      expect(audience_member_for(original_purchase)).to be_present

      original_purchase.unsubscribe_buyer
      expect(audience_member_for(original_purchase)).to be_nil

      original_purchase.reload.update!(can_contact: true)

      member = audience_member_for(original_purchase)
      expect(member).to be_present
      expect(member.details["purchases"].map { _1["id"] }).to include(original_purchase.id)
      expect(member.customer).to be(true)
    end

    it "puts the buyer back in the seller's audience filter results" do
      original_purchase.unsubscribe_buyer
      expect(AudienceMember.filter(seller_id: seller.id, params: { bought_product_ids: [product.id] })).to be_empty

      original_purchase.reload.update!(can_contact: true)

      expect(AudienceMember.filter(seller_id: seller.id, params: { bought_product_ids: [product.id] }).map(&:email))
        .to eq([original_purchase.email])
    end

    it "recovers the original purchase when a renewal charge is the row being re-subscribed" do
      renewal = create(:membership_purchase, link: product, seller:, email: original_purchase.email,
                                             subscription: original_purchase.subscription,
                                             is_original_subscription_purchase: false)
      renewal.update!(can_contact: false)
      # The mixed state seen in production: the original purchase reads as contactable, so a
      # spot-check looks fine, but its audience row was destroyed while it was unsubscribed and
      # nothing ever saved that purchase again to rebuild it.
      audience_member_for(original_purchase).destroy!
      expect(original_purchase.reload.can_contact?).to be(true)

      # A renewal charge is never an audience member in its own right, so adding just this row
      # back would contribute nothing and the buyer would stay invisible.
      expect(renewal.reload.should_be_audience_member?).to be(false)
      renewal.update!(can_contact: true)

      member = audience_member_for(original_purchase)
      expect(member).to be_present
      expect(member.details["purchases"].map { _1["id"] }).to eq([original_purchase.id])
    end

    it "does not resurrect a row for a buyer who is still unsubscribed" do
      original_purchase.unsubscribe_buyer

      # Save a change to another attribute the callback watches, with can_contact still false.
      # Re-saving can_contact: false alone would be a no-op save, so the callback would bail at
      # its first guard and the example would pass without exercising anything.
      original_purchase.reload.update!(is_access_revoked: true)

      expect(original_purchase.reload.can_contact?).to be(false)
      expect(audience_member_for(original_purchase)).to be_nil
    end

    it "does not pay for a rebuild when the buyer is being unsubscribed" do
      # Rebuilding is self-correcting, so an unsubscribe would still end up with the right
      # (absent) row — but it would re-read every purchase the buyer has to get there. The
      # can_contact? condition keeps the expensive path on the re-subscribe side only.
      allow(AudienceMember).to receive(:find_or_initialize_by).and_call_original

      original_purchase.unsubscribe_buyer

      expect(audience_member_for(original_purchase)).to be_nil
      expect(AudienceMember).not_to have_received(:find_or_initialize_by)
    end
  end

  describe ".deferring_audience_member_rebuilds" do
    let!(:original_purchase) { create(:membership_purchase, link: product, seller:) }

    it "rebuilds once for the buyer instead of once per purchase row" do
      4.times { create(:purchase, link: create(:product, user: seller), seller:, email: original_purchase.email) }
      original_purchase.unsubscribe_buyer

      allow(AudienceMember).to receive(:find_or_initialize_by).and_call_original

      Purchase.deferring_audience_member_rebuilds do
        Purchase.where(email: original_purchase.email, seller_id: seller.id, can_contact: false).find_each do |purchase|
          purchase.update!(can_contact: true)
        end
        # Nothing is rebuilt until the block finishes.
        expect(audience_member_for(original_purchase)).to be_nil
      end

      member = audience_member_for(original_purchase)
      expect(member.details["purchases"].size).to eq(5)
      expect(AudienceMember).to have_received(:find_or_initialize_by).once
    end

    it "rebuilds immediately when there is no block in progress" do
      original_purchase.unsubscribe_buyer

      original_purchase.reload.update!(can_contact: true)

      expect(audience_member_for(original_purchase)).to be_present
    end

    it "still rebuilds when the block raises partway through" do
      other = create(:purchase, link: create(:product, user: seller), seller:, email: original_purchase.email)
      original_purchase.unsubscribe_buyer

      expect do
        Purchase.deferring_audience_member_rebuilds do
          original_purchase.reload.update!(can_contact: true)
          raise "boom"
        end
      end.to raise_error("boom")

      # The block bailed out, so the rebuild did not run — but the deferral state must not leak
      # into later saves, which have to rebuild immediately again.
      other.reload.update!(can_contact: true)
      expect(audience_member_for(original_purchase)).to be_present
    end
  end

  describe "a new purchase for a buyer who unsubscribed" do
    it "stays uncontactable for one-off purchases" do
      first = create(:purchase, link: create(:product, user: seller), seller:)
      first.unsubscribe_buyer

      second = create(:purchase, link: create(:product, user: seller), seller:, email: first.email)

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

      expect(renewal.can_contact?).to be(true)
      member = audience_member_for(original_purchase)
      expect(member.details["purchases"].map { _1["id"] }).to include(original_purchase.id)
    end
  end

  describe "a concurrent insert race on the same (seller, email) pair" do
    let!(:purchase) { create(:purchase, link: create(:product, user: seller), seller:, can_contact: true) }

    it "retries once and updates the winner's row instead of raising" do
      # Simulate losing the insert race: a concurrent process's insert (the "winner") lands
      # between this process's find_or_initialize_by and its own save!, so the first save!
      # raises RecordNotUnique. The winner row is inserted via `insert_all` (not `create!`) so
      # it doesn't also trip the `save!` stub below. Stubbing save! rather than
      # find_or_initialize_by exercises the real retry lookup, including the `.lock` it takes
      # on the second pass.
      save_count = 0
      allow_any_instance_of(AudienceMember).to receive(:save!).and_wrap_original do |original|
        save_count += 1
        if save_count == 1
          AudienceMember.insert_all([{ seller_id: seller.id, email: purchase.email,
                                       details: { "follower" => { "id" => 1, "created_at" => Time.current.iso8601 } },
                                       created_at: Time.current, updated_at: Time.current }])
          raise ActiveRecord::RecordNotUnique, "boom"
        end
        original.call
      end

      expect { purchase.send(:add_to_audience_member_details) }.not_to raise_error

      member = audience_member_for(purchase)
      expect(member).to be_present
      expect(member.details["purchases"].map { _1["id"] }).to include(purchase.id)
      expect(save_count).to eq(2)
    end

    it "raises if the race persists past the single retry" do
      allow_any_instance_of(AudienceMember).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique, "boom")

      expect { purchase.send(:add_to_audience_member_details) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "a LockWaitTimeout on an existing audience_members row" do
    let!(:purchase) { create(:purchase, link: create(:product, user: seller), seller:, can_contact: true) }

    it "does not raise from add_to_audience_member_details and enqueues a refresh" do
      allow_any_instance_of(AudienceMember).to receive(:save!).and_raise(ActiveRecord::LockWaitTimeout, "Lock wait timeout exceeded")
      expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::LockWaitTimeout))

      expect { purchase.send(:add_to_audience_member_details) }.not_to raise_error
      expect(RefreshAudienceMemberJob).to have_enqueued_sidekiq_job(purchase.email, seller.id)
    end

    it "does not raise from remove_from_audience_member_details and enqueues a refresh" do
      purchase.send(:add_to_audience_member_details)
      allow_any_instance_of(AudienceMember).to receive(:save!).and_raise(ActiveRecord::LockWaitTimeout, "Lock wait timeout exceeded")
      allow_any_instance_of(AudienceMember).to receive(:destroy!).and_raise(ActiveRecord::LockWaitTimeout, "Lock wait timeout exceeded")
      expect(ErrorNotifier).to receive(:notify).with(instance_of(ActiveRecord::LockWaitTimeout))

      expect { purchase.send(:remove_from_audience_member_details) }.not_to raise_error
      expect(RefreshAudienceMemberJob).to have_enqueued_sidekiq_job(purchase.email, seller.id)
    end
  end
end
