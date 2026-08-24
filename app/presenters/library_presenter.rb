# frozen_string_literal: true

class LibraryPresenter
  include Rails.application.routes.url_helpers
  include Pagy::Backend

  PER_PAGE = 15
  private_constant :PER_PAGE

  attr_reader :logged_in_user

  def initialize(logged_in_user)
    @logged_in_user = logged_in_user
  end

  def library_props(page: nil, sort: nil, query: nil, creator_ids: [], bundle_ids: [], show_archived_only: false)
    sort = sort == "purchase_date" ? "purchase_date" : "recently_updated"

    base = logged_in_user.purchases.visible_in_library
    denied_ids = no_access_membership_purchase_ids(base)
    visible = base.where.not(id: denied_ids)
    replaced_ids = replaced_bundle_purchase_ids(base)
    cards = visible.where.not(id: replaced_ids)

    pagination, page_purchases = paged_purchases(filtered(cards, query:, creator_ids:, bundle_ids:, show_archived_only:), sort:, page:)

    {
      results: build_cards(page_purchases),
      pagination:,
      creators: creators_for_tab(cards, show_archived_only:),
      bundles: bundle_filter_options(base, replaced_ids),
      bundle_downloads: bundle_downloads(base, bundle_ids),
      archived_count: visible.is_archived.count,
      unarchived_count: visible.not_is_archived.count,
      search: {
        sort:,
        query: query.to_s,
        creators: creator_ids,
        bundles: bundle_ids,
        show_archived_only:,
      },
    }
  end

  # The post-checkout redirect lands on the library with `purchase_id` params that can point at
  # any page (or at a bundle row that renders as its members), so the receipt alert and
  # third-party analytics get their own lookup instead of searching the paged results.
  def receipt_purchases(external_ids)
    return [] if external_ids.empty?

    purchases = logged_in_user.purchases.visible_in_library
      .by_external_ids(external_ids)
      .includes(:subscription, link: { alive_third_party_analytics: [] })
    purchases = purchases.reject { |purchase| purchase.link.is_recurring_billing && purchase.subscription && !purchase.subscription.grant_access_to_product? }
    universal_analytics_user_ids = universal_analytics_user_ids(purchases.map { _1.link.user_id })

    purchases.map do |purchase|
      {
        id: purchase.external_id,
        email: purchase.email,
        permalink: purchase.link.unique_permalink,
        has_third_party_analytics: third_party_analytics?(purchase.link, universal_analytics_user_ids),
      }
    end
  end

  private
    def filtered(cards, query:, creator_ids:, bundle_ids:, show_archived_only:)
      scope = show_archived_only ? cards.is_archived : cards.not_is_archived

      # Filtering by links.user_id (not a users join keyed on external_id) keeps MySQL's plan
      # anchored on the cheap purchaser_id index; joining users on external_id sometimes made it
      # drive from links/purchase_state instead, turning Pagy's COUNT(*) into a 100s+ scan
      # (gumroad-private#1824).
      if creator_ids.any?
        creator_user_ids = User.where(external_id: creator_ids).pluck(:id)
        scope = scope.joins(:link).where(links: { user_id: creator_user_ids })
      end

      if bundle_ids.any?
        bundle_link_ids = bundle_ids.filter_map { Link.from_external_id(_1) }
        scope = scope.where(id: BundleProductPurchase.joins(:bundle_purchase).where(purchases: { link_id: bundle_link_ids }).select(:product_purchase_id))
      end

      if query.present?
        like = "%#{ActiveRecord::Base.sanitize_sql_like(query)}%"
        # The creator term mirrors the byline: User#username falls back to external_id, so the
        # display name is name, else username, else that fallback.
        scope = scope.joins(link: :user)
          .where("links.name LIKE :like OR COALESCE(users.name, NULLIF(users.username, ''), users.external_id) LIKE :like", like:)
      end

      scope
    end

    def paged_purchases(scope, sort:, page:)
      scope =
        if sort == "purchase_date"
          scope.order(id: :desc)
        else
          scope.joins(:link).order(Arel.sql("COALESCE(links.content_updated_at, links.created_at) DESC"), id: :desc)
        end

      pagy_object, page_scope = pagy(scope, page: [page.to_i, 1].max, limit: PER_PAGE, overflow: :last_page)

      # The card payload needs deep preloads (previews, thumbnails, avatars); loading by id
      # keeps them off the filtered query so its joins and ordering stay a single flat query.
      page_ids = page_scope.ids
      records = Purchase.where(id: page_ids).includes(
        :subscription,
        :url_redirect,
        :variant_attributes,
        link: {
          display_asset_previews: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } },
          thumbnail_alive: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } },
          user: { avatar_attachment: :blob }
        }
      ).index_by(&:id)

      pagination = { page: pagy_object.page, pages: pagy_object.pages, from: pagy_object.from, to: pagy_object.to, count: pagy_object.count }
      [pagination, page_ids.map { records[_1] }]
    end

    def build_cards(purchases)
      replacement_redirects = replacement_redirects_for(purchases)
      product_seller_data = {}

      purchases.map do |purchase|
        product = purchase.link
        product_seller_data[product.user.id] ||= product.user.username && {
          name: product.user.name || product.user.username,
          profile_url: product.user.profile_url(recommended_by: "library"),
          avatar_url: product.user.avatar_url
        }
        {
          product: {
            name: product.name,
            creator: product_seller_data[product.user.id],
            thumbnail_url: product.thumbnail_or_cover_url,
            native_type: product.native_type,
          },
          purchase: {
            id: purchase.external_id,
            is_archived: purchase.is_archived,
            download_url: library_download_location(purchase, replacement_redirects),
            variants: purchase.variant_attributes&.map(&:name)&.join(", "),
          }
        }
      end
    end

    # A purchase whose subscription row is missing stays visible: wrongly hiding a purchase is
    # the worse failure (gumroad-private#1585).
    def no_access_membership_purchase_ids(base)
      pairs = base.joins(:link).merge(Link.is_recurring_billing).pluck(:id, :subscription_id)
      return [] if pairs.empty?

      subscriptions = Subscription.where(id: pairs.map(&:last).compact.uniq).includes(:link).index_by(&:id)
      pairs.filter_map do |purchase_id, subscription_id|
        subscription = subscriptions[subscription_id]
        purchase_id if subscription && !subscription.grant_access_to_product?
      end
    end

    # A bundle row is dropped only when at least one of its member rows survived into the
    # buyer's library — otherwise the members render instead of nothing and the purchase
    # vanishes entirely (gumroad-private#1585).
    def replaced_bundle_purchase_ids(base)
      bundle_purchase_ids = base.is_bundle_purchase.pluck(:id)
      return [] if bundle_purchase_ids.empty?

      BundleProductPurchase
        .where(bundle_purchase_id: bundle_purchase_ids)
        .where(product_purchase_id: base.select(:id))
        .distinct
        .pluck(:bundle_purchase_id)
    end

    # Counts ignore the search query and creator/bundle selections (matching the
    # pre-pagination page, which derived them from the unfiltered result set), so a
    # buyer's other creators stay selectable while one is filtered.
    def creators_for_tab(cards, show_archived_only:)
      scope = show_archived_only ? cards.is_archived : cards.not_is_archived
      counts_by_user_id = scope.joins(:link).group("links.user_id").count
      User.where(id: counts_by_user_id.keys).map do |creator|
        {
          id: creator.external_id,
          name: creator.name || creator.username || creator.external_id,
          count: counts_by_user_id[creator.id],
        }
      end
    end

    def bundle_filter_options(base, replaced_ids)
      return [] if replaced_ids.empty?

      link_ids = base.where(id: replaced_ids).order(id: :desc).pluck(:link_id).uniq
      links = Link.where(id: link_ids).index_by(&:id)
      link_ids.map { |link_id| { id: links[link_id].external_id, label: links[link_id].name } }
    end

    def bundle_downloads(base, bundle_ids)
      return [] if bundle_ids.empty?

      bundle_link_ids = bundle_ids.filter_map { Link.from_external_id(_1) }
      return [] if bundle_link_ids.empty?

      bundle_purchases = base.is_bundle_purchase
        .where(link_id: bundle_link_ids)
        .includes(:url_redirect, :link)
        .order(id: :desc)
        .to_a
        .uniq(&:link_id)
      bundle_purchases.filter_map do |purchase|
        redirect = purchase.url_redirect
        next if redirect.blank?
        next if redirect.bundle_archive_product_files.empty?

        archive = redirect.bundle_archive
        {
          id: purchase.link.external_id,
          label: purchase.link.name,
          download_url: archive.present? ? url_redirect_download_archive_path(redirect.token) : nil,
        }
      end
    end

    def universal_analytics_user_ids(user_ids)
      return Set.new if user_ids.empty?

      ThirdPartyAnalytic.where(user_id: user_ids.uniq, link_id: nil)
        .alive.where(location: ["receipt", "all"]).distinct.pluck(:user_id).to_set
    end

    def third_party_analytics?(product, universal_analytics_user_ids)
      product.alive_third_party_analytics.any? { |a| a.location == "receipt" || a.location == "all" } ||
        universal_analytics_user_ids.include?(product.user_id)
    end

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
      # Only the viewer's own renewals are eligible, even though a transfer can leave the one paid
      # renewal on the previous owner. UrlRedirectsController#check_permissions authorizes against
      # the RENDERED purchase's purchaser, so publishing that renewal's redirect would bounce the
      # viewer to purchaser verification they cannot clear (it wants the previous owner's email).
      # A transferred membership whose signup was refunded therefore keeps no link here.
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
