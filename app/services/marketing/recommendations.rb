# frozen_string_literal: true

# Builds the channel picker for a published product: one open action per live
# channel (copy derived only from the product's own name and description, never
# invented claims), plus the disabled "Coming soon" channels.
class Marketing::Recommendations
  SENTENCE_BOUNDARY = /(?<=[.!?])\s+/
  EMAIL_GATE_ERROR = "email_eligibility_not_met"

  def initialize(product:, seller:)
    @product = product
    @seller = seller
  end

  def call
    Marketing::Channel::ALL.map do |channel, config|
      entry = { channel:, label: config[:label], live: config[:live] }
      next entry unless config[:live]

      entry.merge(send(:"#{channel}_entry"))
    end
  end

  def self.copy_for(product)
    name = product.name.to_s.squish
    sentence = product.plaintext_description.split(SENTENCE_BOUNDARY).first.to_s.squish
    copy = sentence.present? ? "#{name}: #{sentence}" : name
    copy.truncate(Marketing::Action::MAX_COPY_LENGTH, separator: " ")
  end

  private
    attr_reader :product, :seller

    def x_entry
      seller.reload
      action = action_for("x")
      # Keep the displayed account and token on the same snapshot through serialization.
      action.user = seller
      {
        connected: seller.twitter_oauth_token.present? && seller.twitter_oauth_secret.present?,
        handle: seller.twitter_handle,
        connect_path: Rails.application.routes.url_helpers.settings_social_connections_path,
        intent_url: intent_url(action),
        action:,
      }
    end

    # Prepares the draft the seller sends from the Emails tab. A seller who cannot email
    # yet gets the reason the draft is missing rather than a draft they cannot send.
    def email_entry
      action = action_for("email")
      launch_email = Marketing::LaunchEmail.new(product:, seller:, utm_link: action.utm_link)
      counts = launch_email.recipient_counts

      unless seller.eligible_to_send_emails?
        action.error_code = EMAIL_GATE_ERROR
        action.mark_blocked! unless action.blocked?

        return { eligible: false, blocked_reason: email_blocked_reason, requirements: email_requirements,
                 counts:, draft: nil, action: }
      end

      if action.blocked?
        # Cleared with the block: the recorded reason no longer describes this seller.
        action.error_code = nil
        action.clear_block!
      end
      draft = launch_email.installment
      # Nothing reports back from the Emails tab, so the seller's own scheduling or sending
      # is what closes this action out, read off the Installment on the next look.
      action.approve! if action.recommended? && draft.present? && email_state(draft) != "draft"

      { eligible: true, blocked_reason: nil, requirements: email_requirements, counts:,
        declined: launch_email.declined?, draft: email_draft_payload(draft), action: }
    end

    def email_requirements
      { sales_cents_total: seller.sales_cents_total,
        min_sales_cents_required: Installment::MINIMUM_SALES_CENTS_VALUE }
    end

    def email_blocked_reason
      return "Your account can't send emails while it's suspended." if seller.suspended?

      "You can email your customers once you've made at least " \
        "#{Money.from_cents(Installment::MINIMUM_SALES_CENTS_VALUE).format(no_cents: true)} in sales and received a payout."
    end

    def email_draft_payload(installment)
      return if installment.nil?

      {
        id: installment.external_id,
        subject: installment.name,
        state: email_state(installment),
        edit_url: Rails.application.routes.url_helpers.edit_email_path(installment.external_id),
      }
    end

    def email_state(installment)
      if installment.published_at.present?
        blast = installment.latest_regular_blast
        return blast.delivery_status if blast&.requested_at.present?

        return "published"
      end
      return "scheduled" if installment.ready_to_publish?

      "draft"
    end

    def action_for(channel)
      return @actions[channel] if (@actions ||= {}).key?(channel)

      @actions[channel] = Marketing::Action.find_or_create_open!(user: seller, link: product, channel:) do |action|
        action.copy = self.class.copy_for(product)
        action.utm_link = launch_utm_link(channel)
      end
    end

    # One tagged link per channel, so the seller's analytics can tell the launch email's clicks
    # from the post's. They share `utm_campaign`, so the launch still reads as one campaign.
    def launch_utm_link(channel)
      attrs = { seller:, target_resource_type: "product_page", target_resource_id: product.id,
                utm_source: channel, utm_medium: channel == "email" ? "email" : "social",
                utm_campaign: "launch" }
      UtmLink.alive.find_by(attrs) || UtmLink.create!(attrs.merge(title: "#{product.name} — #{channel} launch"))
    end

    def intent_url(action)
      "https://twitter.com/intent/tweet?#{{ text: action.copy, url: action.utm_link.short_url }.to_query}"
    end
end
