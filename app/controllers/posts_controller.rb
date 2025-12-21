# frozen_string_literal: true

class PostsController < ApplicationController
  include CustomDomainConfig

  before_action :authenticate_user!, only: %i[send_for_purchase send_missed_posts]
  after_action :verify_authorized, only: %i[send_for_purchase send_missed_posts]
  before_action :fetch_post, only: %i[show send_for_purchase redirect_from_purchase_id increment_post_views]
  before_action :fetch_purchase, only: %i[send_for_purchase send_missed_posts]
  before_action :set_user_and_custom_domain_config, only: %i[show]
  before_action :check_if_needs_redirect, only: %i[show]

  rescue_from CustomersService::CustomerDNDEnabledError do |exception|
    if action_name.in?(%w[send_for_purchase send_missed_posts])
      render json: { message: "This customer has opted out of receiving emails." }, status: :unprocessable_entity
    else
      raise exception
    end
  end

  rescue_from CustomersService::SellerNotEligibleError do |exception|
    if action_name.in?(%w[send_for_purchase send_missed_posts])
      render json: { message: "You are not eligible to resend this email." }, status: :forbidden
    else
      raise exception
    end
  end

  def show
    @title = "#{@post.name} - #{@post.user.name_or_username}"
    @hide_layouts = true
    @show_user_favicon = true
    @body_class = "post-page"
    @body_id = "post_page"

    @on_posts_page = true

    # Set @user instance variable to apply third-party analytics config in layouts/_head partial.
    @user = @post.seller
    seller_context = SellerContext.new(
      user: logged_in_user,
      seller: (logged_in_user && policy(@post).preview?) ? current_seller : logged_in_user
    )
    @post_presenter = PostPresenter.new(
      pundit_user: seller_context,
      post: @post,
      purchase_id_param: params[:purchase_id]
    )
    purchase = @post_presenter.purchase

    if purchase
      @subscription = purchase.subscription
    end

    e404 if @post_presenter.e404?
  end

  def redirect_from_purchase_id
    authorize Installment

    # redirects legacy installment paths like /library/purchase/:purchase_id
    # to the new path /:username/p/:slug
    redirect_to build_view_post_route(post: @post, purchase_id: params[:purchase_id])
  end

  def send_for_purchase
    authorize @post

    CustomersService.send_post!(post: @post, purchase: @purchase)

    head :no_content
  end

  def send_missed_posts
    authorize [:audience, @purchase], :send_missed_posts?

    CustomersService.send_missed_posts_for!(purchase: @purchase, workflow_id: params[:workflow_id])

    render json: { message: "Missed emails are queued for delivery" }, status: :ok
  end

  def increment_post_views
    skip = is_bot?
    skip |= logged_in_user.present? && (@post.seller_id == current_seller.id || logged_in_user.is_team_member?)
    skip |= impersonating_user&.id

    create_post_event(@post) unless skip

    render json: { success: true }
  end

  private
    def fetch_post
      return if @post.present?

      if params[:slug]
        @post = Installment.find_by_slug(params[:slug])
      elsif params[:id]
        @post = Installment.find_by_external_id(params[:id])
      else
        e404
      end
      e404 if @post.blank?
    end

    def check_if_needs_redirect
      if !@is_user_custom_domain && @user.subdomain_with_protocol.present?
        redirect_to custom_domain_view_post_url(slug: @post.slug, host: @user.subdomain_with_protocol,
                                                params: request.query_parameters),
                    status: :moved_permanently, allow_other_host: true
      end
    end

    def fetch_purchase
      @purchase = current_seller.sales.find_by_external_id(params[:purchase_id])
      e404_json if @purchase.blank?
    end
end
