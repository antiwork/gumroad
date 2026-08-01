# frozen_string_literal: true

# Resolves the `{{first_name}}` merge token sellers can put in a post/blast.
#
# A bare token is never rendered empty: on the newest 4,000 successful purchases platform-wide
# only 45% carry a usable name (95% of paid, 40% of free), so an un-defaulted token would produce
# "Hi ," for the majority of a free-heavy blast. `{{first_name|friend}}` overrides DEFAULT per post.
#
# Both PostSendgridApi and PostResendApi derive their substitution sets independently, so this
# lives here rather than in either — a one-sided change silently personalizes only part of a blast.
module PostEmailPersonalization
  DEFAULT = "there"

  # Matches {{first_name}} and {{first_name|Anything but a brace}}.
  TOKEN = /\{\{\s*first_name\s*(?:\|([^}]*))?\}\}/

  module_function

  def token?(content) = content.present? && content.match?(TOKEN)

  # Followers have no name column at all, so a pure follower always takes the default.
  def resolve(recipient)
    name = recipient[:purchase]&.full_name.presence || recipient[:purchaser_name].presence
    first_token(name)
  end

  def first_token(name)
    return nil if name.blank?
    name.to_s.strip.split(/\s+/).first.presence
  end

  # SendGrid substitutes by exact key, so every distinct spelling of the token that appears in
  # this post needs its own key/value pair — including each per-post default.
  def substitutions(content, first_name)
    content.to_s.scan(TOKEN).map(&:first).uniq.index_with { first_name.presence || _1.presence&.strip || DEFAULT }
      .transform_keys { _1.nil? ? "{{first_name}}" : "{{first_name|#{_1}}}" }
  end

  def apply(content, first_name)
    content.gsub(TOKEN) { first_name.presence || Regexp.last_match(1).presence&.strip || DEFAULT }
  end
end
