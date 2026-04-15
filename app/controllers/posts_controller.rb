# frozen_string_literal: true

class PostsController < ApplicationController
  include CustomDomainConfig

  include PageMeta::Favicon
  include PageMeta::Post

  layout "inertia", only: [:show]

  before_action :authenticate_user!, only: %i[send_for_purchase]
  after_action :verify_authorized, only: %i[send_for_purchase]
  before_action :fetch_post, only: %i[send_for_purchase]
  before_action :ensure_seller_is_eligible_to_send_emails, only: %i[send_for_purchase]
  before_action :set_user_and_custom_domain_config, only: %i[show]
  before_action :check_if_needs_redirect, only: %i[show]

  def show
    # Skip fetching post again if it's already fetched in check_if_needs_redirect
    @post || fetch_post(false)

    # Set @user instance variable to apply third-party analytics config in layouts/_head partial.
    @user = @post.seller
    seller_context = SellerContext.new(
      user: logged_in_user,
      seller: (logged_in_user && policy(@post).preview?) ? current_seller : logged_in_user
    )
    post_presenter = PostPresenter.new(
      pundit_user: seller_context,
      post: @post,
      purchase_id_param: params[:purchase_id]
    )

    set_meta_tag(title: "#{@post.name} - #{@post.user.name_or_username}")
    set_post_page_meta(@post, post_presenter)
    set_favicon_meta_tags(@user)

    e404 if post_presenter.e404?

    render inertia: "Posts/Show", props: post_presenter.post_component_props
  end

  def redirect_from_purchase_id
    authorize Installment

    # redirects legacy installment paths like /library/purchase/:purchase_id
    # to the new path /:username/p/:slug
    fetch_post(false)
    redirect_to build_view_post_route(post: @post, purchase_id: params[:purchase_id])
  end

  def send_for_purchase
    authorize @post

    purchase = current_seller.sales.find_by_external_id!(params[:purchase_id])

    # Limit the number of emails sent per post to avoid abuse.
    Rails.cache.fetch("post_email:#{@post.id}:#{purchase.id}", expires_in: 8.hours) do
      CreatorContactingCustomersEmailInfo.where(purchase:, installment: @post).destroy_all

      PostEmailApi.process(
        post: @post,
        recipients: [
          {
            email: purchase.email,
            purchase:,
            url_redirect: purchase.url_redirect,
            subscription: purchase.subscription,
          }.compact_blank
        ])
      true
    end

    head :no_content
  end

  def increment_post_views
    fetch_post(false)

    skip = is_bot?
    skip |= logged_in_user.present? && (@post.seller_id == current_seller.id || logged_in_user.is_team_member?)
    skip |= impersonating_user&.id

    create_post_event(@post) unless skip

    render json: { success: true }
  end

  private
    def fetch_post(viewed_by_seller = true)
      if params[:slug]
        @post = Installment.find_by_slug(params[:slug])
      elsif params[:id]
        @post = Installment.find_by_external_id(params[:id])
      else
        e404
      end
      e404 if @post.blank?

      if viewed_by_seller
        e404 if @post.seller != current_seller
      end

      if @post.seller_id?
        e404 if @post.seller.suspended?
      elsif @post.link_id?
        e404 if @post.link.seller&.suspended?
      end
    end

    def check_if_needs_redirect
      fetch_post(false)

      if !@is_user_custom_domain && @user.subdomain_with_protocol.present?
        redirect_to custom_domain_view_post_url(slug: @post.slug, host: @user.subdomain_with_protocol,
                                                params: request.query_parameters),
                    status: :moved_permanently, allow_other_host: true
      end
    end

    def ensure_seller_is_eligible_to_send_emails
      seller = @post.seller || @post.link.seller
      unless seller&.eligible_to_send_emails?
        render json: { message: "You are not eligible to resend this email." }, status: :unauthorized
      end
    end
end
