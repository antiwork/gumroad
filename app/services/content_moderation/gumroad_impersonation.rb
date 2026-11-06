# frozen_string_literal: true

# Names that make Gumroad's own mail look like a message from Gumroad staff. Receipts use the
# seller name as the From name and the product name in the subject ("You got Gumroad Security
# Team!"), so a new account could send staff-looking mail from noreply@customers.gumroad.com.
#
# Only sellers who have not proven themselves are checked: established sellers selling guides
# like "Gumroad Payout Tips" are left alone.
module ContentModeration::GumroadImpersonation
  MESSAGE = "can't look like a message from Gumroad staff. Remove words like \"Gumroad Security\" or \"Payout Verification\"."
  # The account must be this old, or have made a paid sale, before these names are allowed.
  PROVEN_ACCOUNT_AGE = 30.days

  GUMROAD = /g[\W_]*u[\W_]*m[\W_]*r[\W_]*o[\W_]*a[\W_]*d/i
  STAFF_WORDS = /\b(security|payouts?|verif(y|ied|ication)|trust|safety|compliance|billing|official|admin|staff|alerts?|notices?|support\s+team|help\s*desk)\b/i

  class << self
    def impersonates?(text)
      normalized = normalize(text)
      normalized.match?(GUMROAD) && normalized.match?(STAFF_WORDS)
    end

    def unproven_seller?(user)
      return false if user.nil? || gumroad_staff?(user)

      (user.created_at.nil? || user.created_at > PROVEN_ACCOUNT_AGE.ago) && !user.sales.paid.exists?
    end

    def gumroad_staff?(user)
      user.try(:confirmed?) && user.email.to_s.downcase.end_with?("@gumroad.com")
    end

    def gumroad_address?(email)
      email.to_s.downcase.strip.end_with?("@gumroad.com")
    end

    private
      # Fold look-alike characters ("Ｇｕｍｒｏａｄ") and drop invisible ones before matching.
      def normalize(text)
        text.to_s.unicode_normalize(:nfkc).gsub(/\p{Cf}/, "")
      end
  end
end
