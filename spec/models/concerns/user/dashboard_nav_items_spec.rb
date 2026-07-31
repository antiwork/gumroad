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

    it "does not write again when the item is already recorded" do
      user.promote_nav_item!("workflows")

      expect { user.promote_nav_item!("workflows") }.not_to change { user.reload.updated_at }
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
  end
end
