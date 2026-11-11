# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe GumroadBlog::PostsController, inertia: true do
  let(:blog_owner) { create(:user, username: "gumroad") }

  describe "GET index" do
    let!(:published_post_1) do
      create(
        :audience_post,
        :published,
        seller: blog_owner,
        shown_on_profile: true,
        published_at: 2.days.ago,
        name: "First Blog Post",
      )
    end

    let!(:published_post_2) do
      create(
        :audience_post,
        :published,
        seller: blog_owner,
        shown_on_profile: true,
        published_at: 1.day.ago,
        name: "Second Blog Post",
      )
    end

    let!(:hidden_post) do
      create(
        :audience_post,
        :published,
        seller: blog_owner,
        shown_on_profile: false,
        published_at: 3.days.ago
      )
    end

    let!(:unpublished_post) do
      create(
        :audience_post,
        seller: blog_owner,
        shown_on_profile: true,
        published_at: nil
      )
    end

    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { :posts }
      let(:policy_klass) { GumroadBlog::PostsPolicy }
    end

    it "only includes posts that are visible on profile, order by published_at descending" do
      get :index

      expect(response).to have_http_status(:ok)
      expect(inertia.props[:posts]).to eq(
        [
          {
            slug: published_post_2.slug,
            subject: published_post_2.subject,
            published_at: published_post_2.published_at,
            featured_image_url: published_post_2.featured_image_url,
            message_snippet: published_post_2.message_snippet,
            tags: published_post_2.tags,
          },
          {
            slug: published_post_1.slug,
            subject: published_post_1.subject,
            published_at: published_post_1.published_at,
            featured_image_url: published_post_1.featured_image_url,
            message_snippet: published_post_1.message_snippet,
            tags: published_post_1.tags,
          },
        ]
      )
    end

    context "served HTML" do
      render_views

      it "gives the served head its own title, description and canonical" do
        get :index

        html = Nokogiri::HTML.parse(response.body)
        expect(html.at_css("title").text).to eq("Gumroad Blog")
        expect(html.at_css("link[rel=canonical]")["href"]).to end_with("/blog")
        expect(html.at_css("meta[name=description]")["content"]).to be_present
        expect(html.at_css("meta[property='og:title']")["content"]).to eq("Gumroad Blog")
        expect(html.at_css("meta[property='og:description']")["content"]).to eq(html.at_css("meta[name=description]")["content"])
        expect(html.at_css("meta[property='og:url']")["content"]).to end_with("/blog")
      end

      it "serves the visible posts' titles and links inside noscript so a crawler without JavaScript can reach them" do
        get :index

        noscripts = Nokogiri::HTML.parse(response.body).css("noscript")
        expect(noscripts.size).to eq(1)
        fallback = noscripts.first

        expect(fallback.at_css("h1").text).to eq("Gumroad Blog")
        expect(fallback.css("a").map { |a| [a["href"], a.text] }).to eq(
          [
            ["/blog/p/#{published_post_2.slug}", "Second Blog Post"],
            ["/blog/p/#{published_post_1.slug}", "First Blog Post"],
          ]
        )
      end

      it "cannot be made to close the noscript element from a post title" do
        published_post_1.update!(name: %(Hi</NOSCRIPT><img src=x onerror="alert(1)">))

        get :index

        expect(response.body.scan(%r{</noscript}i).size).to eq(1)
        expect(response.body).not_to include("<img src=x")
      end
    end
  end

  describe "GET show" do
    let!(:post) do
      create(
        :audience_post,
        :published,
        seller: blog_owner,
        shown_on_profile: true,
        slug: "test-post",
        name: "Test Post",
        message: "<p>Hello from the blog</p>"
      )
    end

    it_behaves_like "authorize called for action", :get, :show do
      let(:record) { post }
      let(:policy_klass) { GumroadBlog::PostsPolicy }
      let(:request_params) { { slug: post.slug } }
    end

    it "sets @props correctly" do
      get :show, params: { slug: post.slug }

      post_props = PostPresenter.new(pundit_user: controller.pundit_user, post: post, purchase_id_param: nil).post_component_props

      expect(inertia.props[:external_id]).to eq(post_props[:external_id])
      expect(inertia.props[:subject]).to eq(post_props[:subject])
      expect(inertia.props[:published_at]).to eq(post_props[:published_at])
      expect(inertia.props[:message]).to eq(post_props[:message])
      expect(inertia.props[:call_to_action]).to eq(post_props[:call_to_action])
    end

    context "served HTML" do
      render_views

      it "serves the post body inside noscript so a crawler without JavaScript sees the text" do
        get :show, params: { slug: post.slug }

        noscript = Nokogiri::HTML.parse(response.body).at_css("noscript")
        expect(noscript).to be_present
        expect(noscript.at_css("h1").text.strip).to eq(post.name)
        expect(noscript.text).to include("Hello from the blog")
      end

      it "cannot be made to close the noscript element from post content" do
        # Browsers end the raw-text element on any casing, and a sanitizer can leave the
        # sequence inside an attribute value, so try both shapes.
        post.update!(message: %(<p>hello</p></NOSCRIPT><img src=x onerror="alert(1)"><a title="</NoScript><b>">x</a>))

        get :show, params: { slug: post.slug }

        expect(response.body.scan(%r{</noscript}i).size).to eq(1)
        expect(response.body).not_to include(%(<img src=x onerror="alert(1)">))
        expect(response.body).not_to include("<b>")
      end
    end

    it "gives the served head the post's own title, canonical URL and description" do
      get :show, params: { slug: post.slug }

      meta_tags = controller.send(:meta_tags)
      presenter = PostPresenter.new(pundit_user: controller.pundit_user, post: post, purchase_id_param: nil)

      expect(controller.send(:page_title)).to eq("Test Post")
      expect(meta_tags["canonical"][:href]).to end_with("/blog/p/test-post")
      expect(meta_tags["meta-name-description"][:content]).to eq(presenter.snippet)
    end

    context "when post is not found" do
      it "raises ActiveRecord::RecordNotFound" do
        expect { get :show, params: { slug: "nonexistent-slug" } }.to raise_error(ActiveRecord::RecordNotFound)
      end
    end

    context "when post belongs to different user" do
      let!(:other_user) { create(:named_user) }
      let!(:other_post) do
        create(
          :audience_post,
          :published,
          seller: other_user,
          shown_on_profile: true,
          slug: "other-post"
        )
      end

      it "raises ActiveRecord::RecordNotFound" do
        expect { get :show, params: { slug: other_post.slug } }
          .to raise_error(ActiveRecord::RecordNotFound)
      end
    end
  end
end
