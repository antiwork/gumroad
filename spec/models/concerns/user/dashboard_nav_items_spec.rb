# frozen_string_literal: true

require "spec_helper"

describe User::DashboardNavItems do
  let(:user) { create(:user) }

  describe "#promoted_nav_item_keys" do
    it "is empty before seeding" do
      expect(user.promoted_nav_item_keys).to eq []
      expect(user.dashboard_nav_items_seeded?).to be false
    end

    it "drops keys that are no longer promotable" do
      user.update!(promoted_nav_items: %w[workflows retired_destination])

      expect(user.promoted_nav_item_keys).to eq %w[workflows]
    end
  end

  describe "#promote_nav_item!" do
    it "records a promotable item" do
      user.promote_nav_item!("workflows")

      expect(user.reload.promoted_nav_item_keys).to eq %w[workflows]
    end

    it "accepts a symbol" do
      user.promote_nav_item!(:emails)

      expect(user.reload.promoted_nav_item_keys).to eq %w[emails]
    end

    it "ignores core and unknown items" do
      user.promote_nav_item!("products")
      user.promote_nav_item!("not_a_destination")

      expect(user.reload.promoted_nav_items).to be_nil
    end

    it "does not touch the database again when the item is already recorded" do
      user.promote_nav_item!("workflows")

      # The regression that matters is the row lock, not the column value: an already-promoted
      # destination is visited on most page loads, so it must not open a transaction at all.
      writes = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        writes << payload[:sql] if payload[:sql].match?(/FOR UPDATE|UPDATE `users`/)
      end

      user.promote_nav_item!("workflows")

      ActiveSupport::Notifications.unsubscribe(subscriber)
      expect(writes).to be_empty
    end

    it "accumulates across items" do
      user.promote_nav_item!("workflows")
      user.promote_nav_item!("emails")

      expect(user.reload.promoted_nav_item_keys).to match_array %w[workflows emails]
    end

    it "preserves a concurrent write to another json_data attribute" do
      user.promote_nav_item!("workflows")

      User.find(user.id).update!(payout_threshold_cents: 25_00)
      user.promote_nav_item!("emails")

      reloaded = user.reload
      expect(reloaded.promoted_nav_item_keys).to match_array %w[workflows emails]
      expect(reloaded.payout_threshold_cents).to eq 25_00
    end

    it "keeps a promotion another process recorded" do
      user.promote_nav_item!("workflows")
      User.find(user.id).promote_nav_item!("emails")

      # The stale in-memory copy must merge rather than overwrite.
      user.promote_nav_item!("affiliates")

      expect(user.reload.promoted_nav_item_keys).to match_array %w[workflows emails affiliates]
    end
  end

  describe "#seed_promoted_nav_items!" do
    it "credits what the seller's store already contains" do
      create(:product, user:)

      user.seed_promoted_nav_items!(seller: user)

      expect(user.reload.promoted_nav_item_keys).to include "profile"
    end

    it "marks a seller with nothing earned as seeded so it does not re-scan" do
      user.seed_promoted_nav_items!(seller: user)

      expect(user.reload.promoted_nav_items).to eq []
      expect(user.dashboard_nav_items_seeded?).to be true
    end

    it "is a no-op once seeded, even if the store grows" do
      user.seed_promoted_nav_items!(seller: user)
      create(:product, user:)

      user.seed_promoted_nav_items!(seller: user)

      expect(user.reload.promoted_nav_item_keys).to eq []
    end

    it "does not erase promotions recorded before the seed" do
      user.promote_nav_item!("workflows")

      user.seed_promoted_nav_items!(seller: user)

      expect(user.reload.promoted_nav_item_keys).to eq %w[workflows]
    end

    it "seeds a legacy row whose json_data is NULL" do
      # Reading json_data instantiates it and marks the record dirty, and `lock!` refuses a dirty
      # record — so locking `self` here would raise a bare RuntimeError and 500 the page.
      user.update_column(:json_data, nil)
      legacy = User.find(user.id)
      create(:workflow, seller: legacy)

      expect { legacy.seed_promoted_nav_items!(seller: legacy) }.not_to raise_error
      expect(legacy.reload.promoted_nav_item_keys).to include "workflows"
    end

    it "seeds a user whose record would fail validation" do
      # An ungated legacy validation must not keep the seed from persisting: if it did, the
      # seed-once guard would never latch and every page load would re-scan and re-lock the row.
      user.update_column(:google_analytics_id, "UA-12345-6")
      stale = User.find(user.id)
      expect(stale).not_to be_valid

      stale.seed_promoted_nav_items!(seller: stale)

      expect(stale.reload.dashboard_nav_items_seeded?).to be true
    end
  end
end
