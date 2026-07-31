# frozen_string_literal: true

class LibraryPresenter
  include Rails.application.routes.url_helpers

  attr_reader :logged_in_user

  def initialize(logged_in_user)
    @logged_in_user = logged_in_user
  end

  def library_cards
    purchases = logged_in_user.purchases
      .visible_in_library
      .includes(
        :subscription,
        :url_redirect,
        :variant_attributes,
        :bundle_purchase,
        :product_purchases,
        link: {
          alive_third_party_analytics: [],
          display_asset_previews: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } },
          thumbnail_alive: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } },
          user: { avatar_attachment: :blob }
        }
      )
      .find_each(batch_size: 3000, order: :desc) # required to avoid full table scans. See https://github.com/gumroad/web/pull/25970
      .to_a

    user_ids = purchases.map { |p| p.link.user_id }.uniq
    users_with_universal_analytics = ThirdPartyAnalytic.where(user_id: user_ids, link_id: nil)
      .alive.where(location: ["receipt", "all"]).distinct.pluck(:user_id).to_set

    creators_infos = purchases.flat_map { |purchase| purchase.link.user }.uniq.group_by(&:id).transform_values(&:first)
    creators = creators_infos.values.map do |creator|
      { id: creator.external_id, name: creator.name || creator.username || creator.external_id }
    end
    # `is_bundle_purchase` tells the page "my member rows render instead of me", so it must be
    # false whenever none of those member rows survived into this result set — otherwise the
    # buyer's only row for that purchase is filtered out and the product vanishes from their
    # library entirely (gumroad-private#1585).
    library_purchase_ids = purchases.map(&:id).to_set
    replaced_by_members = purchases.filter_map do |purchase|
      next unless purchase.is_bundle_purchase?
      purchase.id if purchase.product_purchases.any? { |member| library_purchase_ids.include?(member.id) }
    end.to_set
    bundles = purchases.filter_map do |purchase|
      { id: purchase.link.external_id, label: purchase.link.name } if replaced_by_members.include?(purchase.id)
    end.uniq { _1[:id] }
    product_seller_data = {}
    replacement_redirects = replacement_redirects_for(purchases)

    purchases = purchases.map do |purchase|
      next if purchase.link.is_recurring_billing && !purchase.subscription.grant_access_to_product?

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
          has_third_party_analytics: product.alive_third_party_analytics.any? { |a| a.location == "receipt" || a.location == "all" } ||
            users_with_universal_analytics.include?(product.user_id),
        },
        purchase: {
          id: purchase.external_id,
          email: purchase.email,
          is_archived: purchase.is_archived,
          download_url: library_download_location(purchase, replacement_redirects),
          variants: purchase.variant_attributes&.map(&:name)&.join(", "),
          bundle_id: purchase.bundle_purchase&.link&.external_id,
          is_bundle_purchase: replaced_by_members.include?(purchase.id),
        }
      }
    end.compact
    return purchases, creators, bundles
  end

  private
    def library_download_location(purchase, replacement_redirects)
      return purchase.url_redirect&.download_page_url unless purchase.stripe_refunded

      replacement_redirects[purchase.id]&.download_page_url
    end

    def replacement_redirects_for(purchases)
      refunded_originals = purchases.select do |purchase|
        purchase.stripe_refunded? &&
          purchase.subscription_id.present? &&
          (purchase.is_original_subscription_purchase? || purchase.is_gift_receiver_purchase?)
      end
      return {} if refunded_originals.empty?

      purchase_pairs = refunded_originals.map { [_1.subscription_id, _1.link_id] }.uniq
      candidates = Purchase
        .where([:subscription_id, :link_id] => purchase_pairs)
        .where(purchaser_id: logged_in_user.id, purchase_state: %w[successful test_successful])
        .not_fully_refunded
        .not_chargedback_or_chargedback_reversed
        .not_is_access_revoked
        .not_is_original_subscription_purchase
        .not_is_gift_receiver_purchase
        .eager_load(:url_redirect)
        .order(succeeded_at: :desc, id: :desc)
        .group_by { [_1.subscription_id, _1.link_id] }

      refunded_originals.to_h do |purchase|
        successful_state = purchase.subscription.is_test_subscription? ? "test_successful" : "successful"
        renewal = candidates.fetch([purchase.subscription_id, purchase.link_id], []).find do |candidate|
          candidate.purchase_state == successful_state &&
            candidate.url_redirect.present?
        end

        [purchase.id, renewal&.url_redirect]
      end
    end
end
