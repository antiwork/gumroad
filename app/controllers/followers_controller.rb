# frozen_string_literal: true

class FollowersController < ApplicationController
  layout "inertia"
  include CustomDomainConfig
  include Pagy::Backend
  include PageMeta::Post
  include ValidateRecaptcha

  PUBLIC_ACTIONS = %i[new create from_embed_form confirm cancel].freeze
  before_action :authenticate_user!, except: PUBLIC_ACTIONS
  after_action :verify_authorized, except: PUBLIC_ACTIONS

  before_action :fetch_follower, only: %i[confirm cancel destroy]
  before_action :set_user_and_custom_domain_config, only: :new

  FOLLOWERS_PER_PAGE = 20

  def index
    authorize [:audience, Follower]

    create_user_event("followers_view")

    set_meta_tag(title: "Subscribers")
    set_meta_tag(property: "og:title", content: "Posts")

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
    if follow_needs_captcha?(followed_user_from_params)
      message = ValidateRecaptcha::CAPTCHA_FAILURE_MESSAGE
      respond_to do |format|
        format.html { redirect_to custom_domain_subscribe_path, alert: message }
        format.json { render json: { success: false, message: }, status: :unprocessable_entity }
      end
      return
    end

    follower = create_follower(params)

    respond_to do |format|
      format.html do
        return redirect_to custom_domain_subscribe_path, alert: "Sorry, something went wrong." if follower.nil?
        return redirect_to custom_domain_subscribe_path, alert: follower.errors.full_messages.to_sentence if follower.errors.present?

        redirect_to custom_domain_subscribe_path, notice: follow_confirmation_message(follower), status: :see_other
      end
      format.json do
        if follower.nil?
          render json: { success: false, message: "Sorry, something went wrong." }, status: :unprocessable_entity
          return
        end
        if follower.errors.present?
          render json: { success: false, message: follower.errors.full_messages.to_sentence }, status: :unprocessable_entity
          return
        end

        render json: { success: true, message: follow_confirmation_message(follower) }
      end
    end
  end

  def new
    redirect_to @user.profile_url, allow_other_host: true
  end

  # JSON serves the gumroad:follow bridge on custom HTML pages, where the
  # trusted wrapper fetches this endpoint and relays the outcome into the
  # sandboxed page — a redirect would be invisible there. Every other format
  # keeps the pre-existing render/redirect behavior (a plain `if` rather than
  # respond_to, so formats that never had an explicit branch don't start
  # raising UnknownFormat). Both formats 404 on the same predicate: a seller
  # that doesn't resolve to a public profile.
  def from_embed_form
    followed_user = followed_user_from_params
    if FollowRecaptcha.required?(followed_user)
      # The embed form is copy-pasted HTML living on someone else's website, so
      # there is no CAPTCHA there for the visitor to solve — which is also why
      # this endpoint is the one an abuser would script. For a seller we haven't
      # reviewed, refuse the follow outright and point the visitor at the
      # seller's own subscribe page, which does render a challenge, so a real
      # person can still finish subscribing in one more click.
      subscribe_url = custom_domain_subscribe_url(host: followed_user.subdomain_with_protocol) if followed_user.subdomain.present?
      message = "Please subscribe from #{followed_user.name_or_username}'s Gumroad page so we can confirm you're not a bot."
      return render json: { success: false, message: }, status: :unprocessable_entity if request.format.json?

      return render inertia: "Followers/FromEmbedForm", props: { success: false, message:, subscribe_url: }
    end

    @follower = create_follower(params, source: Follower::From::EMBED_FORM)

    if @follower.nil? || @follower.errors.present?
      message = @follower&.errors&.full_messages&.to_sentence || "Something went wrong. Please try to follow the creator again."
      user = User.find_by_external_id(params[:seller_id])
      if request.format.json?
        return e404_json unless user.try(:username)
        return render json: { success: false, message: }, status: :unprocessable_entity
      end
      flash[:warning] = message
      e404 unless user.try(:username)
      return redirect_to user.profile_url, allow_other_host: true
    end

    message = follow_confirmation_message(@follower)
    return render json: { success: true, message: } if request.format.json?
    render inertia: "Followers/FromEmbedForm", props: { success: true, message: }
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
    respond_to do |format|
      format.html { render inertia: "Followers/Cancel" }
      format.json do
        render json: {
          success: true,
          follower_id:
        }
      end
    end
  end

  private
    # True when this follow submission had to pass a CAPTCHA and didn't.
    #
    # Both public entry points check it, because a challenge on only one of them
    # is no challenge at all: the two endpoints take the same parameters, so
    # anyone scripting /follow would simply script /follow_from_embed_form
    # instead.
    def follow_needs_captcha?(followed_user)
      return false unless FollowRecaptcha.required?(followed_user)

      !valid_recaptcha_response?(site_key: FollowRecaptcha.site_key, surface: FollowRecaptcha::SURFACE)
    end

    def followed_user_from_params
      @followed_user_from_params ||= User.find_by_external_id(params[:seller_id])
    end

    # One home for the visitor-facing outcome copy, shared by #create and
    # #from_embed_form so the subscribe page, the third-party embed form, and
    # the custom-page follow bridge can never drift apart.
    def follow_confirmation_message(follower)
      follower.confirmed? ?
        "You are now following #{follower.user.name_or_username}!" :
        "Check your inbox to confirm your follow request."
    end

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
