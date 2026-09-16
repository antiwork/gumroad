# frozen_string_literal: true

# Builds the channel picker for a published product: one open action per live
# channel (copy derived only from the product's own name and description, never
# invented claims), plus the disabled "Coming soon" channels.
class Marketing::Recommendations
  SENTENCE_BOUNDARY = /(?<=[.!?])\s+/

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
      {
        connected: seller.twitter_oauth_token.present? && seller.twitter_oauth_secret.present?,
        handle: seller.twitter_handle,
        connect_path: Rails.application.routes.url_helpers.settings_social_connections_path,
        intent_url: intent_url(action_for("x")),
        action: action_for("x"),
      }
    end

    def action_for(channel)
      return @actions[channel] if (@actions ||= {}).key?(channel)

      @actions[channel] = Marketing::Action.find_or_create_open!(user: seller, link: product, channel:) do |action|
        action.copy = self.class.copy_for(product)
        action.utm_link = launch_utm_link(channel)
      end
    end

    def launch_utm_link(channel)
      attrs = { seller:, target_resource_type: "product_page", target_resource_id: product.id,
                utm_source: channel, utm_medium: "social", utm_campaign: "launch" }
      UtmLink.alive.find_by(attrs) || UtmLink.create!(attrs.merge(title: "#{product.name} — #{channel} launch"))
    end

    def intent_url(action)
      "https://twitter.com/intent/tweet?#{{ text: action.copy, url: action.utm_link.short_url }.to_query}"
    end
end
