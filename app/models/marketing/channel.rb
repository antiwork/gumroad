# frozen_string_literal: true

# Per-channel readiness. Flipping a channel live is adding its executor and
# setting `live: true` here; the picker renders non-live channels as "Coming soon".
module Marketing::Channel
  ALL = {
    "x" => { label: "X", live: true, executor: "Marketing::Channels::X" },
    "instagram" => { label: "Instagram", live: false },
    "youtube" => { label: "YouTube", live: false },
    "tiktok" => { label: "TikTok", live: false },
  }.freeze

  # Recorded on the shared action row but NOT a posting channel: the launch card's cart
  # toggle drives a Workflow, so it has no place in the posting picker and no executor.
  # It is the same channel as the workflow's own recipient type; a spec pins the two.
  ABANDONED_CART = "abandoned_cart"

  # name => persisted marketing_actions.channel value. The column is a string, so the value
  # is the channel name and a channel can be added anywhere without moving existing rows.
  def self.action_channels
    ALL.keys.index_by(&:itself).merge(ABANDONED_CART => ABANDONED_CART)
  end

  # A channel that is not a posting channel (abandoned cart) has no entry here, and both
  # lookups have to answer for it rather than raise: clients can ask about any action.
  def self.live?(channel) = ALL.fetch(channel.to_s) { {} }.fetch(:live, false)

  def self.executor_for(channel) = ALL.fetch(channel.to_s).fetch(:executor).constantize
end
