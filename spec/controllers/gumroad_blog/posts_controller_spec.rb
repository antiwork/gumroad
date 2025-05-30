# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe GumroadBlog::PostsController do
  let(:blog_owner) { create(:user, username: "gumroad") }

  before { Feature.activate(:gumroad_blog) }

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
      expect(assigns[:props][:posts]).to eq(
        [
          {
            url: gumroad_blog_post_path(published_post_2.slug),
            subject: published_post_2.subject,
            published_at: published_post_2.published_at,
            featured_image_url: published_post_2.featured_image_url,
            message_snippet: published_post_2.message_snippet,
            tags: published_post_2.tags,
          },
          {
            url: gumroad_blog_post_path(published_post_1.slug),
            subject: published_post_1.subject,
            published_at: published_post_1.published_at,
            featured_image_url: published_post_1.featured_image_url,
            message_snippet: published_post_1.message_snippet,
            tags: published_post_1.tags,
          },
        ]
      )
    end

    context "when then feature is disabled" do
      before { Feature.deactivate(:gumroad_blog) }

      it "raises routing error" do
        expect { get :index }.to raise_error(ActionController::RoutingError, "Not Found")
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
        name: "Test Post"
      )
    end

    it_behaves_like "authorize called for action", :get, :show do
      let(:record) { post }
      let(:policy_klass) { GumroadBlog::PostsPolicy }
      let(:request_params) { { slug: post.slug } }
    end

    it "sets @props correctly" do
      get :show, params: { slug: post.slug }

      expect(assigns[:props]).to eq(PostPresenter.new(pundit_user: controller.pundit_user, post: post, purchase_id_param: nil).post_component_props)
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

    context "when feature is disabled" do
      before { Feature.deactivate(:gumroad_blog) }

      it "raises routing error" do
        expect { get :show, params: { slug: post.slug } }
          .to raise_error(ActionController::RoutingError, "Not Found")
      end
    end
  end
end
