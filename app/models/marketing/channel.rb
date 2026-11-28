# frozen_string_literal: true

# Persist the channel name itself so adding a channel never repoints existing actions.
module Marketing::Channel
  ALL = {
    "x" => { label: "X", live: true, executor: "Marketing::Channels::X" },
    # Live only for sellers behind the flag until Meta approves the publishing permission.
    "instagram" => { label: "Instagram", live: false, flag: :marketing_instagram_posting, executor: "Marketing::Channels::Instagram" },
    "youtube" => { label: "YouTube", live: false },
    "tiktok" => { label: "TikTok", live: false },
    "email" => { label: "Email", live: true, executor: "Marketing::Channels::Email" },
  }.freeze

  ABANDONED_CART = "abandoned_cart"

  def self.action_channels
    ALL.keys.index_by(&:itself).merge(ABANDONED_CART => ABANDONED_CART)
  end

  def self.live?(channel, seller = nil)
    config = ALL.fetch(channel.to_s) { {} }
    return true if config.fetch(:live, false)

    config[:flag].present? && seller.present? && Feature.active?(config[:flag], seller)
  end

  def self.executor_for(channel) = ALL.fetch(channel.to_s).fetch(:executor).constantize
end
