# frozen_string_literal: true

# Moving one seller's newsletter into Feature announcements (gumroad-private#3664), driven by
# Onetime::MigrateNewsletterSubscribersToFeatureAnnouncements. Retirement is only reachable from
# `migrated`, so the old newsletter can't be turned off before consent rows exist.
class FeatureAnnouncementNewsletterCutover < ApplicationRecord
  STATES = %w[prepared migrating migrated failed retired rolled_back].freeze
  APPLICABLE_STATES = %w[prepared migrating failed].freeze
  # Rolled back means nothing was carried over, so old opt-outs no longer need mirroring.
  TRACKING_STATES = STATES - %w[rolled_back]

  belongs_to :seller, class_name: "User"

  validates :state, inclusion: { in: STATES }

  def self.tracks_opt_outs_for?(seller_id)
    where(seller_id:, state: TRACKING_STATES).exists?
  end

  # Primary and uncached: senders run on workers whose plain reads can go to a lagging replica.
  def self.retired_for?(seller_id)
    ApplicationRecord.connected_to(role: :writing) { uncached { where(seller_id:, state: "retired").exists? } }
  end

  # For a save that would make a follow active. The share lock waits out a retire! holding the row
  # FOR UPDATE and reads its committed state, and holds retire! back until this save commits.
  # Sellers without a cutover row take no lock, so other creators' follows never queue here.
  def self.retired_for_follow?(seller_id)
    ApplicationRecord.connected_to(role: :writing) do
      uncached { where(seller_id:).exists? && where(seller_id:).lock("FOR SHARE").pick(:state) == "retired" }
    end
  end
end
