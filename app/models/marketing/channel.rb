# frozen_string_literal: true

# Per-channel readiness. Flipping a channel live is adding its executor and
# setting `live: true` here; the picker renders non-live channels as "Coming soon".
#
# The persisted `marketing_actions.channel` value is the key itself (a string column), so a
# channel can be added anywhere without repointing rows that already exist.
module Marketing::Channel
  ALL = {
    "x" => { label: "X", live: true, executor: "Marketing::Channels::X" },
    "instagram" => { label: "Instagram", live: false },
    "youtube" => { label: "YouTube", live: false },
    "tiktok" => { label: "TikTok", live: false },
    "email" => { label: "Email", live: true, executor: "Marketing::Channels::Email" },
  }.freeze

  def self.live?(channel) = ALL.fetch(channel.to_s).fetch(:live)

  def self.executor_for(channel) = ALL.fetch(channel.to_s).fetch(:executor).constantize
end
