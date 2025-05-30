# frozen_string_literal: true

class GumroadBlog::PostsController < GumroadBlog::BaseController
  layout "gumroad_blog"

  before_action :hide_layouts
  before_action :set_blog_owner!
  before_action :set_post, only: [:show]

  after_action :verify_authorized

  def index
    authorize [:gumroad_blog, :posts]

    posts = @blog_owner.installments
      .visible_on_profile
      .order(published_at: :desc)

    @props = {
      posts: posts.map do |post|
        {
          url: gumroad_blog_post_path(post.slug),
          subject: post.subject,
          published_at: post.published_at,
          featured_image_url: post.featured_image_url,
          message_snippet: post.message_snippet,
          tags: post.tags,
        }
      end,
    }
  end

  def show
    authorize @post, policy_class: GumroadBlog::PostsPolicy

    @props = PostPresenter.new(pundit_user: pundit_user, post: @post, purchase_id_param: nil).post_component_props
  end

  private
    def set_post
      @post = @blog_owner.installments.find_by!(slug: params[:slug])
    end
end
