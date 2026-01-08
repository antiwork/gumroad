# frozen_string_literal: true

class FollowersController < ApplicationController
  layout "inertia"
  include CustomDomainConfig
  include Pagy::Backend

  PUBLIC_ACTIONS = %i[new create from_embed_form confirm cancel].freeze
  before_action :authenticate_user!, except: PUBLIC_ACTIONS
  after_action :verify_authorized, except: PUBLIC_ACTIONS

  before_action :fetch_follower, only: %i[confirm cancel destroy]
  before_action :set_user_and_custom_domain_config, only: :new

  FOLLOWERS_PER_PAGE = 20

  def index
    authorize [:audience, Follower]

    create_user_event("followers_view")
    @on_posts_page = true
    @title = "Subscribers"

    email = params[:email].to_s.strip

    all_followers = current_seller.followers.active.order(confirmed_at: :desc, id: :desc)
    searched_followers = all_followers
    searched_followers = searched_followers.where("email LIKE ?", "%#{email}%") if email.present?

    pagination, paginated_followers = pagy(
      searched_followers,
      page: params[:page],
      limit: FOLLOWERS_PER_PAGE
    )

    render inertia: "Followers/Index", props: {
      followers: InertiaRails.merge { paginated_followers.as_json(pundit_user:) },
      total_count: all_followers.count,
      page: pagination.page,
      has_more: pagination.next.present?,
      email:,
    }
  end

  def create
    follower = create_follower(params)
    return render json: { success: false, message: "Sorry, something went wrong." } if follower.nil?
    return render json: { success: false, message: follower.errors.full_messages.to_sentence } if follower.errors.present?

    if follower.confirmed?
      render json: { success: true, message: "You are now following #{follower.user.name_or_username}!" }
    else
      render json: { success: true, message: "Check your inbox to confirm your follow request." }
    end
  end

  def new
    redirect_to @user.profile_url, allow_other_host: true
  end

  def from_embed_form
    @follower = create_follower(params, source: Follower::From::EMBED_FORM)
    @hide_layouts = true

    return unless @follower.nil? || @follower.errors.present?

    flash[:warning] = "Something went wrong. Please try to follow the creator again."
    user = User.find_by_external_id(params[:seller_id])
    e404 unless user.try(:username)
    redirect_to user.profile_url, allow_other_host: true
  end

  def confirm
    e404 unless @follower.user.account_active?

    @follower.confirm!

    # Redirect to the followed user's profile
    redirect_to @follower.user.profile_url, notice: "Thanks for the follow!", allow_other_host: true
  end

  def destroy
    authorize [:audience, @follower]

    @follower.mark_deleted!

    redirect_to followers_path, notice: "Follower removed!", status: :see_other
  end

  def cancel
    follower_id = @follower.external_id
    @follower.mark_deleted!
    @hide_layouts = true
    respond_to do |format|
      format.html
      format.json do
        render json: {
          success: true,
          follower_id:
        }
      end
    end
  end

  private
    def create_follower(params, source: nil)
      followed_user = User.find_by_external_id(params[:seller_id])

      return if followed_user.nil?

      follower_email = params[:email]
      follower_user_id = User.find_by(email: follower_email)&.id

      followed_user.add_follower(
        follower_email,
        follower_user_id:,
        logged_in_user:,
        source:
      )
    end

    def fetch_follower
      @follower = Follower.find_by_external_id(params[:id])
      return if @follower

      respond_to do |format|
        format.html { e404 }
        format.json { e404_json }
      end
    end
end
