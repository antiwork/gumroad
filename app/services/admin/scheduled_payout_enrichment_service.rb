# frozen_string_literal: true

class Admin::ScheduledPayoutEnrichmentService
  TOP_CATEGORIES_LIMIT = 3
  ENRICHED_AFFILIATE_TYPES = [DirectAffiliate.name, Collaborator.name].freeze
  private_constant :TOP_CATEGORIES_LIMIT, :ENRICHED_AFFILIATE_TYPES

  def initialize(scheduled_payouts)
    @users = scheduled_payouts.map(&:user).compact.uniq(&:id)
    @user_ids = @users.map(&:id)
  end

  def call
    return {} if @user_ids.empty?

    last_status_changed_at_by_user = build_last_status_changed_at_by_user
    product_counts = Link.alive.where(user_id: @user_ids).group(:user_id).count
    affiliate_counts = Affiliate.alive
      .where(seller_id: @user_ids, type: ENRICHED_AFFILIATE_TYPES)
      .group(:seller_id)
      .count
    unpaid_by_user = Balance.unpaid.where(user_id: @user_ids).group(:user_id).sum(:amount_cents)
    top_categories_by_user = build_top_categories

    @users.index_with do |user|
      unpaid_cents = unpaid_by_user.fetch(user.id, 0)
      {
        product_count: product_counts.fetch(user.id, 0),
        incoming_affiliate_count: affiliate_counts.fetch(user.id, 0),
        risk_state: Admin::UserRiskStatePresenter.new(user, last_status_changed_at: last_status_changed_at_by_user[user.id]).props,
        top_categories: top_categories_by_user.fetch(user.id, []),
        unpaid_balance_cents: unpaid_cents,
        unpaid_balance_formatted: Money.from_cents(unpaid_cents).format,
      }
    end.transform_keys(&:id)
  end

  private
    def build_last_status_changed_at_by_user
      Comment
        .where(
          commentable_type: User.name,
          commentable_id: @user_ids,
          comment_type: Admin::UserRiskStatePresenter::RISK_STATE_COMMENT_TYPES
        )
        .group(:commentable_id)
        .maximum(:created_at)
    end

    def build_top_categories
      counts_by_user_taxonomy = Link.alive
        .where(user_id: @user_ids)
        .where.not(taxonomy_id: nil)
        .group(:user_id, :taxonomy_id)
        .count

      taxonomy_ids = counts_by_user_taxonomy.keys.map(&:last).uniq
      taxonomies_by_id = Taxonomy.where(id: taxonomy_ids).index_by(&:id)

      counts_by_user_taxonomy.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |((user_id, taxonomy_id), count), result|
        taxonomy = taxonomies_by_id[taxonomy_id]
        next unless taxonomy

        result[user_id] << { taxonomy:, count: }
      end.transform_values do |rows|
        rows
          .sort_by { [_1[:count] * -1, _1[:taxonomy].id] }
          .first(TOP_CATEGORIES_LIMIT)
          .map { { slug: _1[:taxonomy].slug, product_count: _1[:count] } }
      end
    end
end
