# frozen_string_literal: true

class Api::Mobile::EmailAudiencePresenter
  AUDIENCE_TYPES = %w[audience seller follower affiliate].freeze
  LABELS = {
    "audience" => "Everyone",
    "seller" => "Customers",
    "follower" => "Followers",
    "affiliate" => "Affiliates"
  }.freeze
  HELP_URL = "https://gumroad.com/help/article/269-balance-page"

  def initialize(seller:)
    @seller = seller
  end

  def as_json(*)
    {
      options: build_options,
      eligibility: build_eligibility,
      has_profile_sections: seller.seller_profile_sections.exists?
    }
  end

  private
    attr_reader :seller

    def build_options
      AUDIENCE_TYPES.filter_map do |type|
        count = audience_count_for(type)
        next if count.zero? && type != "audience"
        { type:, label: LABELS[type], count: }
      end
    end

    def audience_count_for(type)
      stub = Installment.new(seller:, installment_type: type)
      stub.audience_members_count
    rescue StandardError
      0
    end

    def build_eligibility
      reason = ineligibility_reason
      { can_send_emails: reason.nil?, reason:, learn_more_url: reason ? HELP_URL : nil }
    end

    def ineligibility_reason
      return "Your account is currently suspended." if seller.suspended?
      return "You'll be able to send emails after you've earned $100 in total sales." if seller.sales_cents_total < Installment::MINIMUM_SALES_CENTS_VALUE
      return "You'll be able to send emails after your first payout completes." unless seller_has_completed_payouts?
      nil
    end

    def seller_has_completed_payouts?
      seller.send(:has_completed_payouts?)
    end
end
