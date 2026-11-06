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
    return text.presence if text.blank?

    reason = blocked_reason || held_reason
    return text unless reason

    leave_admin_note(reason)
    nil
  end

  private
    attr_reader :text, :seller, :source

    # Templates strip tags before rendering, so screen what the recipient reads.
    def rendered_text
      @rendered_text ||= CGI.unescapeHTML(ActionController::Base.helpers.strip_tags(text))
    end

    def blocked_reason
      result = ContentModeration::Strategies::BlocklistStrategy.new(text: rendered_text).perform
      "blocklist: #{result.reasoning.join(", ")}" if result.status == "flagged"
    end

    def held_reason
      return "links to public-files.gumroad.com" if rendered_text.match?(PUBLIC_FILES_HOST)
      return unless rendered_text.match?(GUMROAD_NOTICE)

      "poses as a Gumroad security or payout notice" if NOTICE_PHRASES.any? { rendered_text.match?(_1) }
    end

    def leave_admin_note(reason)
      return if seller.blank?

      ContentModerationAdminCommentJob.perform_async(
        seller.id, "Held seller text from #{source} (not sent): #{reason}. Text: #{text.truncate(ADMIN_NOTE_TEXT_LIMIT)}"
      )
    rescue StandardError => e
      Rails.logger.error("SellerMailTextGuard failed to queue admin note: #{e.message}")
    end
end
