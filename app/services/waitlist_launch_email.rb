# frozen_string_literal: true

# The follower email that tells a product's waitlist it launched. The seller starts it from the
# Share tab, then edits and sends it in Emails. One per product: the marker finds it again, so the
# seller may change everything else, including its filters.
class WaitlistLaunchEmail
  PRODUCT_KEY = "waitlist_launch_product_id"

  def initialize(product:)
    @product = product
    @seller = product.user
  end

  # Nil when nobody has confirmed a signup, so the Share tab shows nothing.
  def props
    count = product.waitlist_entries.joins(:follower).merge(Follower.active).count
    return if count.zero?

    {
      count:,
      blocked_reason:,
      email: email && { state: email.delivery_state, edit_url: Rails.application.routes.url_helpers.edit_email_path(email.external_id) },
    }
  end

  def find_or_create_email!
    # Serialized on the product: a double click must not start two drafts.
    product.with_lock do
      @email = nil
      email || create_email!
    end
  end

  private
    attr_reader :product, :seller

    # The marker doubles as the SQL prefilter, so this never deserializes the seller's whole email history.
    def email
      @email ||= seller.installments.alive
                       .where("json_data LIKE ?", "%#{PRODUCT_KEY}%")
                       .select { _1.json_data[PRODUCT_KEY].to_i == product.id }
                       .max_by(&:id)
    end

    def blocked_reason
      return if seller.eligible_to_send_emails?
      return "Your account can't send emails while it's suspended." if seller.suspended?

      "You can email your waitlist once you've made at least " \
        "#{Money.from_cents(Installment::MINIMUM_SALES_CENTS_VALUE).format(no_cents: true)} in sales and received a payout."
    end

    def create_email!
      installment = seller.installments.new(
        name: "#{product.name} is out now".truncate(255),
        message:,
        installment_type: Installment::FOLLOWER_TYPE,
        send_emails: true,
        shown_on_profile: false,
      )
      # The filter accessor rewrites json_data wholesale, so the marker is set after it.
      installment.waitlisted_products = [product.unique_permalink]
      installment.json_data[PRODUCT_KEY] = product.id
      installment.save!
      installment
    end

    def message
      name = ERB::Util.html_escape(product.name)
      url = ERB::Util.html_escape(product.long_url)
      %(<p>You asked to hear when #{name} launches. It's out now.</p><p><a href="#{url}" target="_blank" rel="noopener noreferrer">#{url}</a></p>)
    end
end
