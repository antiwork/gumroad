# frozen_string_literal: true

# Seller-written text that Gumroad's own DKIM-signed mail renders verbatim. Flagged text is
# dropped, never sent, and the seller gets an admin note so risk can find it.
class ContentModeration::SellerMailTextGuard
  PUBLIC_FILES_HOST = /public-files\.gumroad\.com/i

  GUMROAD_NOTICE = /\b(gumroad|your (account|payouts?|balance|funds))\b/i
  NOTICE_PHRASES = [
    /security (alert|notice|warning|team)/i,
    /(verify|confirm|validate|secure|restore|reactivate) your (account|identity|payouts?|payout (method|details)|bank)/i,
    /(payouts?|account|funds|balance)[^.]{0,40}\b(on hold|suspended|frozen|locked|limited|at risk)/i,
    /unusual (activity|sign[- ]?in|login)/i,
    /action (is )?required/i,
  ].freeze

  ADMIN_NOTE_TEXT_LIMIT = 300

  def self.screen(text, seller:, source:)
    new(text, seller:, source:).screen
  end

  def initialize(text, seller:, source:)
    @text = text.to_s
    @seller = seller
    @source = source
  end

  # The text to render, or nil when it was dropped.
  def screen
    return if text.blank?

    reason = blocked_reason || held_reason
    return text unless reason

    leave_admin_note(reason)
    nil
  end

  private
    attr_reader :text, :seller, :source

    def fragment
      @fragment ||= Loofah.fragment(text)
    end

    # What the recipient reads: line breaks kept between blocks, entities decoded,
    # invisible characters dropped, and whitespace runs collapsed the way HTML renders them.
    def rendered_text
      @rendered_text ||= normalize(Loofah.fragment(text).to_text(encode_special_chars: false)).gsub(/[[:space:]]+/, " ")
    end

    # The receipt keeps sanitized links, so a URL can also sit in an href. Browsers
    # drop whitespace and map ideographic full stops to dots in a URL's host.
    def text_and_links
      @text_and_links ||= [
        rendered_text,
        *fragment.xpath(".//@*").map { normalize(CGI.unescape(_1.value).scrub).gsub(/[[:space:]]+/, "").tr("\u3002", ".") },
      ].join(" ")
    end

    def normalize(string)
      string.unicode_normalize(:nfkc).gsub(/\p{Cf}/, "")
    end

    def blocked_reason
      result = ContentModeration::Strategies::BlocklistStrategy.new(text: text_and_links).perform
      "blocklist: #{result.reasoning.join(", ")}" if result.status == "flagged"
    end

    def held_reason
      return "links to public-files.gumroad.com" if text_and_links.match?(PUBLIC_FILES_HOST)
      return unless rendered_text.match?(GUMROAD_NOTICE)

      "poses as a Gumroad security or payout notice" if NOTICE_PHRASES.any? { rendered_text.match?(_1) }
    end

    def leave_admin_note(reason)
      return if seller.blank?

      ContentModerationAdminCommentJob.perform_async(
        seller.id, "Held mail text from #{source} (not sent): #{reason}. Text: #{text.truncate(ADMIN_NOTE_TEXT_LIMIT)}"
      )
    rescue StandardError => e
      ErrorNotifier.notify(e, seller_id: seller.id, source:)
    end
end
