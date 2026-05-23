# frozen_string_literal: true

require "test_helper"

class CommentPresenterTest < ActiveSupport::TestCase
  self.described_class = CommentPresenter


  context_ CommentPresenter do
  context_ "#comment_component_props" do
      let(:seller) { create(:named_seller) }
      let(:commenter) { create(:user) }
      let(:product) { create(:product, user: seller) }
      let(:product_post) { create(:published_installment, link: product, installment_type: "product", shown_on_profile: true) }
      let(:comment) { create(:comment, commentable: product_post, author: commenter) }
      let(:purchase) { nil }
      let(:presenter) { described_class.new(pundit_user:, comment:, purchase:) }

  context_ "when signed in user is the commenter" do
        let(:pundit_user) { SellerContext.new(user: commenter, seller: commenter) }

  test "returns comment details needed to present on frontend" do
          travel_to(DateTime.current) do
            props = presenter.comment_component_props

            expect(props).to eq(
              id: comment.external_id,
              parent_id: nil,
              author_id: commenter.external_id,
              author_name: commenter.display_name,
              author_avatar_url: ActionController::Base.helpers.image_url("gumroad-default-avatar-5.png"),
              purchase_id: nil,
              content: { original: comment.content, formatted: CGI.escapeHTML(comment.content) },
              created_at: DateTime.current.utc.iso8601,
              created_at_humanized: "less than a minute ago",
              depth: 0,
              is_editable: true,
              is_deletable: true
            )
          end
        end

  test "returns both original content as well as formatted content" do
          content = %(That's a great article!<script type="text/html">console.log("Executing evil script...")</script>)
          comment = create(:comment, content:)
          presenter = described_class.new(pundit_user:, comment:, purchase:)

          expect(presenter.comment_component_props[:content]).to eq(
            original: content,
            formatted: "That&#39;s a great article!&lt;script type=&quot;text/html&quot;&gt;console.log(&quot;Executing evil script...&quot;)&lt;/script&gt;",
          )
        end

  test "returns formatted content by turning URLs into noreferrer hyperlinks" do
          content = %(Nice article! Please visit my website at https://example.com)
          comment = create(:comment, content:)
          presenter = described_class.new(pundit_user:, comment:, purchase:)

          expect(presenter.comment_component_props[:content]).to eq(
            original: content,
            formatted: %(Nice article! Please visit my website at <a href="https://example.com" target="_blank" rel="noopener noreferrer nofollow">https://example.com</a>),
          )
        end

  test "returns comment details with 'is_deletable' set to true" do
          expect(presenter.comment_component_props[:is_deletable]).to eq(true)
        end

  test "returns comment details with 'is_editable' set to true" do
          expect(presenter.comment_component_props[:is_editable]).to eq(true)
        end
      end

  context_ "when signed in user is the author of the post" do
        let(:pundit_user) { SellerContext.new(user: seller, seller:) }

  test "returns comment details with 'is_deletable' set to true" do
          expect(presenter.comment_component_props[:is_deletable]).to eq(true)
        end

  test "returns comment details with 'is_editable' set to false" do
          expect(presenter.comment_component_props[:is_editable]).to eq(false)
        end
      end

  context_ "when signed in user is admin for seller (author of the post)" do
        let(:logged_in_user) { create(:user, username: "adminforseller") }
        let(:pundit_user) { SellerContext.new(user: logged_in_user, seller:) }

        before do
          create(:team_membership, user: logged_in_user, seller:, role: TeamMembership::ROLE_ADMIN)
        end

  test "returns comment details with 'is_deletable' set to true" do
          expect(presenter.comment_component_props[:is_deletable]).to eq(true)
        end

  test "returns comment details with 'is_editable' set to false" do
          expect(presenter.comment_component_props[:is_editable]).to eq(false)
        end
      end

  context_ "when signed in user is neither the commenter nor the author of the post" do
        let(:other_user) { create(:user) }
        let(:pundit_user) { SellerContext.new(user: other_user, seller: other_user) }


  test "returns comment details with 'is_deletable' set to false" do
          expect(presenter.comment_component_props[:is_deletable]).to eq(false)
        end

  test "returns comment details with 'is_editable' set to false" do
          expect(presenter.comment_component_props[:is_editable]).to eq(false)
        end
      end

  context_ "when user is not signed in" do
        let(:pundit_user) { SellerContext.logged_out }

  test "returns comment details with 'is_deletable' set to false" do
          expect(presenter.comment_component_props[:is_deletable]).to eq(false)
        end

  test "returns comment details with 'is_editable' set to false" do
          expect(presenter.comment_component_props[:is_editable]).to eq(false)
        end

  test "returns the default avatar URL with 'author_avatar_url'" do
          expect(presenter.comment_component_props[:author_avatar_url]).to eq(ActionController::Base.helpers.image_url("gumroad-default-avatar-5.png"))
        end
      end

  context_ "when comment author has an avatar picture" do
        let(:commenter) { create(:user, :with_avatar) }
        let(:pundit_user) { SellerContext.new(user: commenter, seller: commenter) }

  test "returns the URL to author's avatar with 'author_avatar_url'" do
          expect(presenter.comment_component_props[:author_avatar_url]).to eq(commenter.avatar_url)
        end
      end

  context_ "when comment author does not have an avatar picture" do
        let(:pundit_user) { SellerContext.new(user: commenter, seller: commenter) }

  test "returns the default avatar URL with 'author_avatar_url'" do
          expect(presenter.comment_component_props[:author_avatar_url]).to eq(ActionController::Base.helpers.image_url("gumroad-default-avatar-5.png"))
        end
      end
    end
  end
end
