# frozen_string_literal: true

class GumroadBlog::PostsController < GumroadBlog::BaseController
  include PageMeta::Post

  layout "inertia"
  before_action :set_blog_owner!
  before_action :set_post, only: [:show]

  after_action :verify_authorized

  def index
    authorize [:gumroad_blog, :posts]

    posts = @blog_owner.installments
      .visible_on_profile
      .order(published_at: :desc)

    post_props = posts.map do |post|
      {
        slug: post.slug,
        subject: post.subject,
        published_at: post.published_at,
        featured_image_url: post.featured_image_url,
        message_snippet: post.message_snippet,
        tags: post.tags,
      }
    end

    # The index renders through Inertia, so without these the served head kept the app-wide
    # "Gumroad" title with no description or canonical. Same shape as #show.
    title = "Gumroad Blog"
    description = "Product updates, announcements and stories from the Gumroad team."
    canonical_url = gumroad_blog_root_url

    set_meta_tag(title:)
    set_meta_tag(tag_name: "link", rel: "canonical", href: canonical_url, head_key: "canonical")
    set_meta_tag(name: "description", content: description)
    set_meta_tag(property: "og:title", content: title)
    set_meta_tag(property: "og:description", content: description)
    set_meta_tag(property: "og:url", content: canonical_url)

    # Post subjects are stored content; the partial only ever emits them as escaped text.
    @seo_links_fallback = {
      heading: title,
      description:,
      sections: [
        {
          links: post_props.map { |post| { label: post[:subject], href: gumroad_blog_post_path(post[:slug]) } },
        },
      ],
    }

    render inertia: "GumroadBlog/Posts/Index", props: { posts: post_props }
  end

  def show
    authorize @post, policy_class: GumroadBlog::PostsPolicy

    post_presenter = PostPresenter.new(
      pundit_user: pundit_user,
      post: @post,
      purchase_id_param: nil
    )
    # The blog renders through Inertia, so without these the served head keeps the app-wide
    # "Gumroad" title and carries no description or canonical: every post looks identical to a
    # crawler that does not run JavaScript. Mirrors PostsController#show.
    set_meta_tag(title: @post.name)
    set_meta_tag(tag_name: "link", rel: "canonical", href: gumroad_blog_post_url(@post.slug), head_key: "canonical")
    set_post_page_meta(@post, post_presenter)

    # The post body only reaches the page through the Inertia payload, so a crawler without
    # JavaScript saw a title and nothing else. The fallback sits inside <noscript>, which a
    # browser parses as raw text until the first closing tag, and this column holds stored
    # HTML: escaping it to plain text keeps a post from closing the element and injecting
    # markup into the page.
    # Keep words apart where block elements used to be: stripping tags alone runs
    # "<p>one</p><p>two</p>" together into "onetwo".
    spaced_body = @post.message.to_s.gsub(%r{</(?:p|div|h[1-6]|li|blockquote|tr|td)>|<br\s*/?>}i, " ")
    plain_body = helpers.strip_tags(spaced_body)
    @seo_article_fallback = { title: @post.name, html: helpers.simple_format(ERB::Util.html_escape(plain_body)) }

    render inertia: "GumroadBlog/Posts/Show", props: post_presenter.post_component_props
  end

  private
    def set_post
      @post = @blog_owner.installments.find_by!(slug: params[:slug])
    end
end
