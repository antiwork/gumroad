# frozen_string_literal: true

class GumroadBlog::PostsController < GumroadBlog::BaseController
  before_action :set_blog_owner!
  before_action :set_post, only: [:show]

  after_action :verify_authorized

  def index
    authorize [:gumroad_blog, :posts]

    @posts = @blog_owner.installments
      .visible_on_profile
      .order(published_at: :desc)
  end

  def show
    authorize @post, policy_class: GumroadBlog::PostsPolicy
  end

  private
    def set_post
      @post = @blog_owner.installments.find_by!(slug: params[:slug])
    end
end
