# frozen_string_literal: true

class LibraryPresenter
  include Rails.application.routes.url_helpers

  attr_reader :logged_in_user

  def initialize(logged_in_user)
    @logged_in_user = logged_in_user
  end

  def library_cards
    purchases = logged_in_user.purchases
      .for_library
      .not_rental_expired
      .not_is_deleted_by_buyer
      .includes(
        :subscription,
        :url_redirect,
        :variant_attributes,
        :bundle_purchase,
        link: {
          display_asset_previews: { file_attachment: :blob },
          thumbnail_alive: { file_attachment: :blob },
          user: { avatar_attachment: :blob }
        }
      )
      .find_each(batch_size: 3000, order: :desc) # required to avoid full table scans. See https://github.com/gumroad/web/pull/25970
      .to_a
    creators_infos = purchases.flat_map { |purchase| purchase.link.user }.uniq.group_by(&:id).transform_values(&:first)
    creator_counts = purchases.uniq(&:link_id).filter(&:not_is_bundle_purchase).group_by(&:seller_id).map do |seller_id, item|
      creator = creators_infos[seller_id]
      { id: creator.external_id, name: creator.name || creator.username || creator.external_id, count: item.size }
    end.sort_by { |creator| creator[:count] }.reverse
    bundles = purchases.filter_map do |purchase|
      { id: purchase.link.external_id, label: purchase.link.name } if purchase.is_bundle_purchase?
    end.uniq { _1[:id] }
    product_seller_data = {}

    purchases = purchases.map do |purchase|
      next if purchase.link.is_recurring_billing && !purchase.subscription.alive?

      product = purchase.link
      product_seller_data[product.user.id] ||= product.user.username && {
        name: product.user.name || product.user.username,
        profile_url: product.user.profile_url(recommended_by: "library"),
        avatar_url: product.user.avatar_url
      }
      {
        product: {
          name: product.name,
          creator_id: product.user.external_id,
          creator: product_seller_data[product.user.id],
          thumbnail_url: product.thumbnail_or_cover_url,
          native_type: product.native_type,
          updated_at: product.content_updated_at || product.created_at,
          permalink: product.unique_permalink,
          has_third_party_analytics: product.has_third_party_analytics?("receipt"),
        },
        purchase: {
          id: purchase.external_id,
          email: purchase.email,
          is_archived: purchase.is_archived,
          download_url: purchase.url_redirect&.download_page_url,
          variants: purchase.variant_attributes&.map(&:name)&.join(", "),
          bundle_id: purchase.bundle_purchase&.link&.external_id,
          is_bundle_purchase: purchase.is_bundle_purchase?,
        }
      }
    end.compact
    return purchases, creator_counts, bundles
  end
end
