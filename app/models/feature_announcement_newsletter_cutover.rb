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

  # The account a newsletter follow maps to, the same way the migration maps it: the recorded link, read
  # with a lock so a link the migration bound after this record was loaded still counts, else the only
  # confirmed account at the address. Nil when none or several.
  def self.subscriber_for(follower)
    uncached do
      linked_id = Follower.where(id: follower.id).lock("FOR SHARE").pick(:follower_user_id)
      next User.find_by(id: linked_id) if linked_id

      email = follower.email.to_s.strip
      confirmed = email.empty? ? [] : User.where(email:).where.not(confirmed_at: nil).limit(2).to_a
      confirmed.first if confirmed.one?
    end
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
