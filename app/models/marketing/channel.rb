# frozen_string_literal: true

module Marketing::Channel
  ALL = {
    "x" => { label: "X", live: true, executor: "Marketing::Channels::X" },
    "instagram" => { label: "Instagram", live: false },
    "youtube" => { label: "YouTube", live: false },
    "tiktok" => { label: "TikTok", live: false },
  }.freeze

  ABANDONED_CART = "abandoned_cart"

  def self.action_channels
    ALL.keys.index_by(&:itself).merge(ABANDONED_CART => ABANDONED_CART)
  end

  def self.live?(channel) = ALL.fetch(channel.to_s) { {} }.fetch(:live, false)

  def self.executor_for(channel) = ALL.fetch(channel.to_s).fetch(:executor).constantize
end
