# frozen_string_literal: true

module User::Posts
  def visible_posts_for(pundit_user:, shown_on_profile: true)
    # The condition below doesn't take into consideration logged-in user's role for logged-in seller
    # This is a non-issue at this moment as all roles have "read" access to posts.
    # To have a more granular access based on role, the logic below needs to be refactored to use a
    # policy scope via Pundit (https://github.com/varvet/pundit#scopes)
    #
    if pundit_user.seller == self
      visible_posts = installments.not_workflow_installment.alive
      return shown_on_profile ? visible_posts.shown_on_profile : visible_posts
    end

    follower_post_ids = seller_post_ids = product_post_ids = affiliate_post_ids = nil
    audience_posts = installments.where("installment_type = ?", Installment::AUDIENCE_TYPE)
    audience_post_ids = audience_posts.map(&:id)
    display_audience_posts = false

    public_post_ids = audience_posts.shown_on_profile.map(&:id)

    if pundit_user.user
      follower = follower_by_email(pundit_user.user.email)
      if follower.present?
        follower_post_ids = installments.where("installment_type = ?", Installment::FOLLOWER_TYPE)
                                        .filter_map { |post| post.id if post.follower_passes_filters(follower) }
        display_audience_posts = true
      end

      purchases = sales.for_visible_posts(purchaser_id: pundit_user.user.id)
      if purchases.exists?
        product_post_ids = Set.new
        filters = purchases.joins(:link)
                           .select(:email,
                                   :country,
                                   :ip_country,
                                   "min(purchases.created_at) as min_created_at",
                                   "max(purchases.created_at) as max_created_at",
                                   "min(purchases.price_cents) as min_price_cents",
                                   "max(purchases.price_cents) as max_price_cents",
                                   "group_concat(distinct(links.unique_permalink)) as product_permalinks")
                           .first
                           .attributes
        filters[:variant_external_ids] = []
        purchases.each do |purchase|
          filters[:variant_external_ids] + purchase.variant_attributes.map(&:external_id)

          subscription = purchase.subscription
          terminated_at = subscription.present? && !subscription.alive? ? subscription.deactivated_at : nil

          posts = installments.where(link_id: purchase.link_id)
                              .product_or_variant_type
                              .where("published_at >= ?", purchase.created_at)
          posts = posts.where("published_at < ?", terminated_at) if terminated_at.present?
          posts = posts.filter { |post| subscription.alive_at?(post.published_at) } if subscription.present?
          product_post_ids += posts.filter_map { |post| post.id if post.purchase_passes_filters(purchase) }
        end
        filters = filters.symbolize_keys.except(:id)
        filters[:product_permalinks] = filters[:product_permalinks].split(",").compact if filters[:product_permalinks].present?

        seller_post_ids = installments.where("installment_type = ?", Installment::SELLER_TYPE)
                                      .filter_map { |post| post.id if post.seller_post_passes_filters(**filters) }

        display_audience_posts = true
      end

      affiliate = direct_affiliates.alive.find_by(affiliate_user_id: pundit_user.user.id)
      if affiliate.present?
        affiliate_post_ids = installments.where("installment_type = ?", Installment::AFFILIATE_TYPE)
                                         .filter_map { |post| post.id if post.affiliate_passes_filters(affiliate) }
        display_audience_posts = true
      end
    end

    all_visible_post_ids = [public_post_ids]
    all_visible_post_ids += follower_post_ids if follower_post_ids
    all_visible_post_ids += seller_post_ids if seller_post_ids
    all_visible_post_ids += affiliate_post_ids if affiliate_post_ids
    all_visible_post_ids += audience_post_ids if display_audience_posts
    all_visible_post_ids += product_post_ids.to_a if product_post_ids

    visible_posts = Installment.where(id: all_visible_post_ids)
                               .not_workflow_installment
                               .alive
                               .published

    shown_on_profile ? visible_posts.shown_on_profile : visible_posts
  end

  def last_5_created_posts
    self.installments.order(created_at: :desc).limit(5)
  end
end
