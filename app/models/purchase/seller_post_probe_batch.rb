# frozen_string_literal: true

# Answers "has this seller ever sold one of these products/variants to this
# email?" for a whole page of library purchases using a couple of upfront
# queries instead of one query per seller.
#
# Posts with "hasn't bought X" targeting run an existence probe against the
# post's seller's sales (see WithFiltering#seller_post_passes_filters). The
# mobile library endpoints evaluate posts for a page of purchases at a time,
# and a buyer whose library spans N sellers pays for N separate probes — the
# per-(seller, criteria, email) memoization in `seller_post_filter_cache`
# cannot dedupe across sellers because each probe is scoped to one seller's
# sales. On production this fan-out dominated the mobile library search
# endpoint (antiwork/gumroad#6185: 24 sellers x ~115ms of probes in one
# request).
#
# All of those probes share the same buyer email(s), so instead of asking
# MySQL once per seller we load the buyer's purchase rows across ALL of the
# batch's sellers upfront (one query per distinct buyer email — almost always
# exactly one — plus one query for the purchased variant ids) and answer each
# probe in Ruby against that in-memory set. The row set is small — it is the
# buyer's own purchases from the sellers in their library.
class Purchase::SellerPostProbeBatch
  def initialize(purchases)
    @emails = purchases.filter_map(&:email).uniq
    @seller_ids = purchases.filter_map(&:seller_id).uniq
    @covered_emails = @emails.to_set
    @covered_seller_ids = @seller_ids.to_set
  end

  # The batch can only answer probes for the exact (seller, email) pairs it
  # prefetched: the sellers and buyer emails of the purchases it was built
  # from. Callers must fall back to the SQL probe for anything else — a post
  # from a seller outside the batch (its rows were never loaded), a nil email
  # (which in SQL would match rows with a NULL email column), or an email
  # string that differs from the batch's (probe emails come from the same
  # purchase objects the batch was built from, so exact string comparison is
  # the correct pairing; anything else is answered by SQL instead of guessing
  # at the database collation's equality rules in Ruby).
  def covers?(email:, seller_id:)
    email.present? && @covered_emails.include?(email) && @covered_seller_ids.include?(seller_id)
  end

  # Mirrors the SQL probe in WithFiltering#seller_post_passes_filters:
  #
  #   seller.sales
  #     .not_is_archived_original_subscription_purchase
  #     .not_subscription_or_original_purchase
  #     .by_external_variant_ids_or_products(not_bought_variants, exclude_product_ids)
  #     .exists?(email:)
  #
  # `by_external_variant_ids_or_products` matches a purchase when it carries
  # one of the variants OR is for one of the products when variant ids are
  # given, and only by product otherwise (Purchase::Targeting).
  def matched?(seller_id:, email:, not_bought_variant_external_ids:, exclude_product_ids:)
    rows = rows_by_seller_and_email[[seller_id, email]]
    return false if rows.blank?

    if not_bought_variant_external_ids.present?
      variant_ids = resolved_variant_ids(not_bought_variant_external_ids)
      # Parity with the SQL path's edge case: `Purchase.by_variant([])` is a
      # nil-returning scope, i.e. a no-op filter, so when none of the external
      # ids resolve to an existing variant the UNION in
      # `by_external_variant_ids_or_products` degrades to the seller's whole
      # sales scope and the probe matches any sale to this email.
      return true if variant_ids.empty?

      rows.any? do |purchase_id, link_id|
        exclude_product_ids.include?(link_id) ||
          variant_ids_by_purchase_id[purchase_id]&.intersect?(variant_ids)
      end
    elsif exclude_product_ids.present?
      rows.any? { |_purchase_id, link_id| exclude_product_ids.include?(link_id) }
    else
      # No targeting criteria at all degrades to "any sale to this email"
      # (Purchase::Targeting's `for_products` scope is a no-op on a blank
      # list). Callers guard against this case, but keep SQL parity anyway.
      true
    end
  end

  private
    # Resolves external variant ids the same way the SQL probe does
    # (`BaseVariant.by_external_ids(...).pluck(:id)`): only variants that
    # actually exist count. Memoized per distinct id list — the query is a
    # primary-key lookup and posts sharing targeting criteria reuse the result.
    def resolved_variant_ids(external_ids)
      @resolved_variant_ids ||= {}
      @resolved_variant_ids[external_ids.sort] ||= BaseVariant.by_external_ids(external_ids).pluck(:id).to_set
    end

    # { [seller_id, batch_email] => [[purchase_id, link_id], ...] }
    # Loaded lazily: most requests have no "hasn't bought X" posts at all, and
    # they shouldn't pay for the prefetch.
    #
    # One query per distinct batch email (a page of library purchases almost
    # always carries a single buyer email) rather than one `email IN (...)`
    # query. Querying per email lets the DATABASE decide which rows belong to
    # which batch email: the email comparison uses the column's
    # case-insensitive Unicode collation (exactly like the SQL probe's
    # `exists?(email:)`), and re-deriving that pairing in Ruby (e.g. keying by
    # `String#downcase`) disagrees with the collation for some Unicode
    # strings, which would file rows under a key the probe never looks up.
    def rows_by_seller_and_email
      @rows_by_seller_and_email ||= begin
        grouped = {}
        if @seller_ids.any?
          @emails.each do |email|
            Purchase.where(email:, seller_id: @seller_ids)
                    .not_is_archived_original_subscription_purchase
                    .not_subscription_or_original_purchase
                    .pluck(:seller_id, :id, :link_id)
                    .each { |seller_id, purchase_id, link_id| (grouped[[seller_id, email]] ||= []) << [purchase_id, link_id] }
          end
        end
        grouped
      end
    end

    # { purchase_id => Set[base_variant_id, ...] } for the prefetched rows.
    def variant_ids_by_purchase_id
      @variant_ids_by_purchase_id ||= begin
        purchase_ids = rows_by_seller_and_email.values.flatten(1).map(&:first)
        if purchase_ids.any?
          BaseVariantsPurchase.where(purchase_id: purchase_ids)
                              .pluck(:purchase_id, :base_variant_id)
                              .each_with_object({}) { |(purchase_id, variant_id), grouped| (grouped[purchase_id] ||= Set.new) << variant_id }
        else
          {}
        end
      end
    end
end
