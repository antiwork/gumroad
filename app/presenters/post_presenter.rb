# frozen_string_literal: true

class PostPresenter
  include UsersHelper

  RECENT_UPDATES_LIMIT = 5
  delegate :link, :seller, :id, :message, to: :post, allow_nil: true
  attr_reader :post, :purchase, :pundit_user, :purchase_id_param, :visible_posts

  def initialize(pundit_user:, post:, purchase_id_param:)
    @pundit_user = pundit_user
    @post = post
    @purchase_id_param = purchase_id_param
    @visible_posts = seller.visible_posts_for(pundit_user:, shown_on_profile: false)
    set_purchase
  end

  def post_component_props
    {
      creator_profile: ProfilePresenter.new(pundit_user:, seller:).creator_profile,
      subject: post.subject,
      slug: post.slug,
      external_id: post.external_id,
      purchase_id: purchase&.external_id,
      published_at: post.published_at,
      message: Rinku.auto_link(post.message, :all, 'target="_blank" rel="noopener noreferrer nofollow"'),
      call_to_action: post.call_to_action_url.present? && post.call_to_action_text.present? ? { url: post.call_to_action_url, text: post.call_to_action_text } : nil,
      download_url: post.download_url(purchase&.subscription, purchase),
      has_posts_on_profile: seller.seller_profile_posts_sections.on_profile.any?,
      recent_posts:,
      paginated_comments:,
      comments_max_allowed_depth: Comment::MAX_ALLOWED_DEPTH,
      custom_styles: seller.seller_profile.custom_styles,
    }
  end

  def snippet
    TextScrubber.format(message).squish.first(150)
  end

  def social_image
    @_social_image ||= Post::SocialImage.for(message)
  end

  def e404?
    return false if seller == pundit_user.seller && post.workflow.present?

    if purchase.present?
      !post.eligible_purchase?(purchase)
    else
      visible_posts.exclude?(post)
    end
  end

  private
    def recent_posts
      @recent_posts ||= visible_posts
                            .filter_by_product_id_if_present(link.try(:id))
                            .where.not(id:)
                            .order(published_at: :desc)
                            .page_with_kaminari(1)
                            .per(RECENT_UPDATES_LIMIT)
                            .filter_map do |post|
                              recent_post_data(post) if purchase.nil? || post.purchase_passes_filters(purchase)
                            end
    end

    def recent_post_data(recent_post)
      {
        name: recent_post.name,
        slug: recent_post.slug,
        published_at: recent_post.published_at,
        truncated_description: recent_post.truncated_description,
        purchase_id: recent_post.eligible_purchase_for_user(pundit_user.user)&.external_id
      }
    end

    # for posts targeted to customers of specific products, we need to make sure access is authorized
    # by seeking a purchase record with a purchase_id param or via the logged-in user's access to the purchase
    def set_purchase
      if purchase_id_param
        @purchase = seller.sales
                          .all_success_states
                          .not_fully_refunded
                          .not_chargedback_or_chargedback_reversed
                          .find_by_external_id(purchase_id_param)
      elsif pundit_user.user
        @purchase = Purchase.where(purchaser_id: pundit_user.user.id, link_id: link.try(:id))
                            .successful
                            .not_chargedback_or_chargedback_reversed
                            .not_fully_refunded
                            .first
      end
    end

    def paginated_comments
      return unless post.allow_comments?

      PaginatedCommentsPresenter.new(pundit_user:, commentable: post, purchase:).result
    end
end
