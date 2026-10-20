# frozen_string_literal: true

class LibraryPresenter
  include Rails.application.routes.url_helpers
  include Pagy::Backend

  PER_PAGE = 15
  private_constant :PER_PAGE

  # In-memory twins of the Subscription methods of the same names, over the subscription's purchases
  # sorted by id. "label facts" in library_presenter_spec pins each one to its Subscription original.
  LabelFacts = Struct.new(:subscription, :purchases) do
    def charges_completed?
      subscription.has_fixed_length? && successful.size == subscription.charge_occurrence_count
    end

    def remaining_charges_count
      subscription.has_fixed_length? ? subscription.charge_occurrence_count - successful.size : 0
    end

    # A standing chargeback or full refund still counts toward the installments charged, but the buyer
    # didn't keep that payment, so labels must not call it paid.
    def adjusted_payment_history?
      successful.any?(&:chargedback_not_reversed_or_refunded?)
    end

    def end_time_of_subscription
      last_purchase = successful.last || purchases.select(&:is_free_trial_purchase?).last
      return subscription.free_trial_ends_at if subscription.free_trial_ends_at.present? && last_purchase&.is_free_trial_purchase?

      paid_through = end_time_of_last_paid_period
      return paid_through if paid_through.present? && paid_through > Time.current

      last_purchase_at = last_purchase&.succeeded_at || last_purchase&.created_at
      return Time.current if purchases.last.chargedback_not_reversed_or_refunded? || last_purchase_at.nil?

      last_purchase_at + subscription.period
    end

    private
      def successful
        state = subscription.is_test_subscription ? "test_successful" : "successful"
        @successful ||= purchases.select { _1.purchase_state == state }
      end

      # MySQL sorts NULL succeeded_at last under DESC, so the model's first row is the latest non-NULL one.
      def end_time_of_last_paid_period
        paid_at = successful.reject { _1.stripe_refunded? || (_1.chargeback_date.present? && !_1.chargeback_reversed?) }.filter_map(&:succeeded_at).max
        paid_at.present? ? paid_at + subscription.period : subscription.free_trial_ends_at
      end
  end
  private_constant :LabelFacts

  attr_reader :logged_in_user

  def initialize(logged_in_user)
    @logged_in_user = logged_in_user
  end

  def library_props(page: nil, sort: nil, query: nil, creator_ids: [], bundle_ids: [], show_archived_only: false, subscriptions_only: false)
    sort = sort == "purchase_date" ? "purchase_date" : "recently_updated"
    if subscriptions_only
      # A membership can't be a bundle member, and archiving or removing a card only tidies the
      # Library without stopping billing, so neither filter applies (even from a stale URL).
      bundle_ids = []
      show_archived_only = false
    end

    base = logged_in_user.purchases.visible_in_library
    replaced_ids = replaced_bundle_purchase_ids(base)
    if subscriptions_only
      cards = ongoing_subscription_purchases
      archived_count = 0
      unarchived_count = cards.count
    else
      visible = base.where.not(id: no_access_membership_purchase_ids(base))
      cards = visible.where.not(id: replaced_ids)
      archived_count = visible.is_archived.count
      unarchived_count = visible.not_is_archived.count
    end

    pagination, page_purchases = paged_purchases(filtered(cards, query:, creator_ids:, bundle_ids:, show_archived_only:, subscriptions_only:), sort:, page:)

    {
      results: build_cards(page_purchases, subscriptions_only:),
      pagination:,
      creators: creators_for_tab(cards, show_archived_only:, subscriptions_only:),
      bundles: subscriptions_only ? [] : bundle_filter_options(base, replaced_ids),
      bundle_downloads: bundle_downloads(base, bundle_ids),
      archived_count:,
      unarchived_count:,
      search: {
        sort:,
        query: query.to_s,
        creators: creator_ids,
        bundles: bundle_ids,
        show_archived_only:,
        subscriptions_only:,
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
    def filtered(cards, query:, creator_ids:, bundle_ids:, show_archived_only:, subscriptions_only:)
      scope = archive_partition(cards, show_archived_only:, subscriptions_only:)

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

    def build_cards(purchases, subscriptions_only: false)
      replacement_redirects = replacement_redirects_for(purchases)
      product_seller_data = {}

      label_facts = subscriptions_only ? subscription_label_facts(purchases.map(&:subscription)) : {}

      purchases.map do |purchase|
        # A subscription this account pays for through a row that isn't its own Library purchase (held
        # by another account, or a charge row): show the billing card without that row's purchase id,
        # download link or archive state.
        billing_only = subscriptions_only && !@content_card_ids.include?(purchase.id)
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
            # Subscription and Purchase external ids share one encoding, so the bare id could equal a held card's.
            id: billing_only ? "subscription:#{purchase.subscription.external_id}" : purchase.external_id,
            is_archived: !billing_only && purchase.is_archived,
            download_url: billing_only ? nil : library_download_location(purchase, replacement_redirects),
            variants: purchase.variant_attributes&.map(&:name)&.join(", "),
          }.merge(subscriptions_only ? { subscription: subscription_details(purchase.subscription, label_facts[purchase.subscription_id]) } : {})
        }
      end
    end

    # Archived and removed cards stay listed: those actions never stop billing. A subscription
    # owned by another account (reassignment, gift conversion) stays out; an unowned one is a guest
    # checkout this buyer claimed, and its manage link falls back to the emailed magic link.
    def ongoing_subscription_purchases
      held = logged_in_user.purchases.for_library
        .has_active_subscription
        .where(subscriptions: { user_id: [logged_in_user.id, nil] })
      held_ids = one_card_per_subscription(held)
      # User#transfer_purchases! moves purchases to another account but leaves Subscription#user, so
      # this account can still be billed for (and manage) a subscription whose purchase it no longer holds.
      # Only a held row that survived the filters may veto: a converted gift's receiver row moved here
      # must not hide the payer leg.
      billed_elsewhere = Purchase.for_library
        .has_active_subscription
        .where(subscriptions: { user_id: logged_in_user.id })
        .where.not(subscription_id: Purchase.where(id: held_ids).select(:subscription_id))
      card_ids = held_ids + one_card_per_subscription(billed_elsewhere)
      @content_card_ids = held_ids.to_set
      Purchase.where(id: card_ids + billed_without_content_card_ids(card_ids))
    end

    # for_library drops a charged-back original and every installment after it, yet RecurringChargeWorker
    # keeps billing an installment plan until all of its charges are disputed. Such a plan gets a card
    # from its charge rows, which never carries download access.
    def billed_without_content_card_ids(card_ids)
      listed = Purchase.where(id: card_ids).select(:subscription_id)
      charges = Purchase.all_success_states.not_is_additional_contribution.not_is_gift_sender_purchase.has_active_subscription
      owned = charges.where(subscriptions: { user_id: logged_in_user.id }).where.not(subscription_id: listed)
      claimed = charges.where(subscriptions: { user_id: nil }, purchaser_id: logged_in_user.id).where.not(subscription_id: listed)
      ids = one_card_per_subscription(owned) + one_card_per_subscription(claimed)
      paused = paused_installment_plan_ids(Purchase.where(id: ids).select(:subscription_id))
      Purchase.where(id: ids).where.not(subscription_id: paused).ids
    end

    # Subscription#all_charges_disputed? (which pauses RecurringChargeWorker) for every candidate plan in
    # three queries: each of the plan's successful charges (test_successful on a test subscription) has
    # a chargeback that wasn't reversed. The label facts spec pins it to the model method.
    def paused_installment_plan_ids(subscription_ids)
      plans = Subscription.where(id: subscription_ids).select(&:is_installment_plan?)
      return [] if plans.empty?

      charges = Purchase.where(subscription_id: plans.map(&:id), purchase_state: %w[successful test_successful])
      totals = charges.group(:subscription_id, :purchase_state).count
      standing = totals.merge(charges.not_chargedback_or_chargedback_reversed.group(:subscription_id, :purchase_state).count) { |_, total, kept| total - kept }
      plans.filter_map do |plan|
        key = [plan.id, plan.is_test_subscription? ? "test_successful" : "successful"]
        plan.id if totals.fetch(key, 0).positive? && standing.fetch(key) == totals.fetch(key)
      end
    end

    def one_card_per_subscription(scope)
      scope = scope.where.not(id: no_access_membership_purchase_ids(scope) + converted_gift_receiver_ids(scope))
      scope.group(:subscription_id).pluck(Arel.sql("MAX(purchases.id)"))
    end

    # Gift::ConvertToNonGiftService leaves the recipient's receiver row for access but makes the
    # subscription the payer's, owned by no account when the payer checked out as a guest.
    def converted_gift_receiver_ids(owned)
      owned.is_gift_receiver_purchase.includes(:subscription).reject { _1.subscription.gift? }.map(&:id)
    end

    def archive_partition(cards, show_archived_only:, subscriptions_only:)
      return cards if subscriptions_only

      show_archived_only ? cards.is_archived : cards.not_is_archived
    end

    # Status labels need the same few purchase facts for every card; preloading them for the page
    # keeps the tab at a fixed number of queries instead of several per card. `status` reads the
    # preloaded purchases itself (Subscription#pending_failure?), and `gift?` the preloaded original.
    def subscription_label_facts(subscriptions)
      subscriptions = subscriptions.compact.uniq
      ActiveRecord::Associations::Preloader.new(
        records: subscriptions,
        associations: [:link, :purchases, :true_original_purchase, { last_payment_option: [:price, :installment_plan, :installment_plan_snapshot] }],
      ).call
      subscriptions.to_h { [_1.id, LabelFacts.new(_1, _1.purchases.sort_by(&:id))] }
    end

    def subscription_details(subscription, facts)
      # SubscriptionsController#manage 404s a paid-off installment plan, which stays active until
      # its last period ends.
      manageable = !(subscription.is_installment_plan? && facts.charges_completed?)
      {
        status_label: subscription_status_label(subscription, facts),
        manage_label: subscription.is_installment_plan? ? "Manage installment plan" : "Manage membership",
        manage_url: manageable ? manage_subscription_path(subscription.external_id) : nil,
      }
    end

    # Never promises a charge the subscription won't make: completed fixed-length plans, pending
    # cancellations and card-less gifts (whose receipt says they won't renew) show an end date.
    def subscription_status_label(subscription, facts)
      kind = subscription.is_installment_plan? ? "Installment plan" : nil
      label =
        case subscription.status
        when "pending_failure" then "Payment failed"
        when "payment_method_update_required" then "Payment method update required"
        when "pending_cancellation" then cancellation_label(subscription)
        else ongoing_subscription_label(subscription, facts)
        end
      [kind, label].compact.join(" · ")
    end

    # Subscription#grant_access_to_product? ends a cancelled installment plan's access at once, and a
    # membership's only when the product blocks access after cancellation.
    def cancellation_label(subscription)
      if subscription.is_installment_plan?
        "Cancelled · No further payments"
      elsif subscription.link.block_access_after_membership_cancellation
        dated("Cancelled · Access until", subscription.cancelled_at, fallback: "Cancelled")
      else
        dated("Cancelled · Subscription ends on", subscription.cancelled_at, fallback: "Cancelled")
      end
    end

    def ongoing_subscription_label(subscription, facts)
      next_charge_at = facts.end_time_of_subscription
      remaining = facts.remaining_charges_count
      if facts.charges_completed?
        return dated("Ends on", next_charge_at, fallback: "Ending") unless subscription.is_installment_plan?

        facts.adjusted_payment_history? ? "No payments remaining" : "Paid in full"
      elsif subscription.is_installment_plan?
        progress =
          if facts.adjusted_payment_history?
            "#{remaining} #{"payment".pluralize(remaining)} remaining"
          else
            "#{subscription.charge_occurrence_count - remaining} of #{subscription.charge_occurrence_count} paid"
          end
        next_payment = remaining == 1 ? "Final payment on" : "Next payment on"
        "#{progress} · #{dated(next_payment, next_charge_at, fallback: "Payment due")}"
      elsif subscription.gift? && subscription.credit_card_id.blank?
        dated("Gift · Paid through", next_charge_at, fallback: "Gift")
      elsif subscription.in_free_trial?
        dated("Free trial · First charge on", subscription.free_trial_ends_at, fallback: "Free trial")
      elsif remaining == 1
        dated("Final charge on", next_charge_at, fallback: "Renewal due")
      else
        dated("Renews on", next_charge_at, fallback: "Renewal due")
      end
    end

    def dated(prefix, time, fallback:)
      return fallback unless time&.future?

      "#{prefix} #{time.in_time_zone(logged_in_user.timezone).to_fs(:formatted_date_abbrev_month)}"
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
    def creators_for_tab(cards, show_archived_only:, subscriptions_only:)
      scope = archive_partition(cards, show_archived_only:, subscriptions_only:)
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
      link_ids.filter_map do |link_id|
        link = links[link_id]
        next unless link

        { id: link.external_id, label: link.name }
      end
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
        link = purchase.link
        next unless link

        redirect = purchase.url_redirect
        next if redirect.blank?

        files = redirect.bundle_archive_product_files
        next if files.empty?

        archive = redirect.bundle_archive
        zip_unavailable_reason = nil
        if archive.blank?
          matching = redirect.matching_bundle_archives(files)
          if matching.any? && matching.none? { |existing| existing.queueing? || existing.in_progress? }
            # Retrying is over, so name the reason instead of dropping the row: a vanished ZIP block
            # reads to the buyer as a missing file.
            zip_unavailable_reason = matching.max_by(&:id).too_large? ? "too_large" : "failed"
          end
        end

        {
          id: link.external_id,
          label: link.name,
          download_url: archive.present? ? url_redirect_download_archive_path(redirect.token) : nil,
          zip_unavailable_reason:,
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
