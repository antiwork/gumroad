# frozen_string_literal: true

require "spec_helper"

describe CommentContextPolicy do
  subject { described_class }

  let(:accountant_for_seller) { create(:user, username: "accountantforseller") }
  let(:admin_for_seller) { create(:user, username: "adminforseller") }
  let(:marketing_for_seller) { create(:user, username: "marketingforseller") }
  let(:support_for_seller) { create(:user, username: "supportforseller") }
  let(:seller) { create(:named_seller) }
  let(:buyer) { create(:user) }

  before do
    create(:team_membership, user: accountant_for_seller, seller:, role: TeamMembership::ROLE_ACCOUNTANT)
    create(:team_membership, user: admin_for_seller, seller:, role: TeamMembership::ROLE_ADMIN)
    create(:team_membership, user: marketing_for_seller, seller:, role: TeamMembership::ROLE_MARKETING)
    create(:team_membership, user: support_for_seller, seller:, role: TeamMembership::ROLE_SUPPORT)
  end

  it "assigns accessors" do
    context = SellerContext.new(user: admin_for_seller, seller:)
    policy = described_class.new(context, :record)

    expect(policy.user).to eq(admin_for_seller)
    expect(policy.seller).to eq(seller)
    expect(policy.record).to eq(:record)
  end

  shared_examples "when purchase is specified" do
    context "when installment is a product post" do
      let(:product) { create(:product) }
      let(:commentable) { create(:product_installment, link: product, published_at: 1.day.ago) }

      context "when purchased product and post's product is same" do
        let(:purchase) { create(:purchase, link: product, created_at: 1.second.ago) }
        let(:comment) { build(:comment, commentable:) }

        it "grants access" do
          expect(subject).to permit(seller_context, comment_context)
        end
      end

      context "when purchased product does not match with post's product" do
        let(:purchase) { create(:purchase, created_at: 1.second.ago) }
        let(:comment) { build(:comment, commentable:) }

        it "denies access" do
          expect(subject).not_to permit(seller_context, comment_context)
        end
      end
    end

    context "when post is a variant post" do
      let(:product) { create(:product) }
      let!(:variant_category) { create(:variant_category, link: product) }
      let!(:standard_variant) { create(:variant, variant_category:, name: "Standard") }
      let!(:premium_variant) { create(:variant, variant_category:, name: "Premium") }
      let(:commentable) { create(:variant_installment, link: product, published_at: 1.day.ago, base_variant: premium_variant) }

      context "when post's base variant matches with purchase's variants" do
        let(:purchase) { create(:purchase, link: product, variant_attributes: [premium_variant], created_at: 1.second.ago) }
        let(:comment) { build(:comment, commentable:) }

        it "grants access" do
          expect(subject).to permit(seller_context, comment_context)
        end
      end

      context "when post's base variant does not match with purchase's variants" do
        let(:purchase) { create(:purchase, link: product, variant_attributes: [standard_variant], created_at: 1.second.ago) }
        let(:comment) { build(:comment, commentable:) }

        it "denies access" do
          expect(subject).not_to permit(seller_context, comment_context)
        end
      end
    end

    context "when installment is a seller post" do
      let!(:product) { create(:product, user: seller) }
      let(:commentable) { create(:seller_installment, seller:, published_at: 1.day.ago) }

      context "when purchased product's creator is same as the post's creator" do
        let(:purchase) { create(:purchase, link: product, created_at: 1.second.ago) }
        let(:comment) { build(:comment, commentable:) }

        it "grants access" do
          expect(subject).to permit(seller_context, comment_context)
        end
      end

      context "when purchased product's creator does not match with the post's creator" do
        let(:another_product) { create(:product, user: create(:user)) }
        let(:purchase) { create(:purchase, link: another_product, created_at: 1.second.ago) }
        let(:comment) { build(:comment, commentable:) }

        it "denies access" do
          expect(subject).not_to permit(seller_context, comment_context)
        end
      end
    end
  end

  permissions :index? do
    let(:product) { create(:product, user: seller) }
    let(:commentable) { create(:published_installment, seller:, link: product) }

    context "without purchase" do
      let(:comment_context) { CommentContext.new(comment: nil, commentable:, purchase: nil) }

      it "grants access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).to permit(seller_context, comment_context)
      end

      it "grants access to accountant" do
        seller_context = SellerContext.new(user: accountant_for_seller, seller:)
        expect(subject).to permit(seller_context, comment_context)
      end

      it "grants access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).to permit(seller_context, comment_context)
      end

      it "grants access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).to permit(seller_context, comment_context)
      end

      context "when buyer has a purchase" do
        let!(:purchase) { create(:purchase, link: product, purchaser: buyer, created_at: 1.second.ago) }

        it "grants access to buyer" do
          seller_context = SellerContext.new(user: buyer, seller: buyer)
          expect(subject).to permit(seller_context, comment_context)
        end
      end

      context "when buyer does not have a purchase" do
        it "denies access to buyer" do
          seller_context = SellerContext.new(user: buyer, seller: buyer)
          expect(subject).not_to permit(seller_context, comment_context)
        end
      end

      context "without user logged in" do
        let(:seller_context) { SellerContext.logged_out }

        it "denies access" do
          expect(subject).not_to permit(seller_context, comment_context)
        end

        context "when post is public" do
          let(:commentable) { create(:published_installment, installment_type: Installment::AUDIENCE_TYPE, shown_on_profile: true) }

          it "grants access" do
            expect(subject).to permit(seller_context, comment_context)
          end
        end
      end
    end

    context "with purchase" do
      let(:seller_context) { SellerContext.logged_out }
      let(:comment_context) { CommentContext.new(comment: nil, commentable:, purchase:) }

      it_behaves_like "when purchase is specified"
    end
  end

  permissions :create? do
    context "when user is logged in" do
      let(:comment_context) { CommentContext.new(comment:, commentable: nil, purchase: nil) }

      context "when user is author of the comment's post" do
        let(:comment) { build(:comment, commentable: create(:published_installment, seller:)) }

        it "grants access to owner" do
          seller_context = SellerContext.new(user: seller, seller:)
          expect(subject).to permit(seller_context, comment_context)
        end

        it "denies access to accountant" do
          seller_context = SellerContext.new(user: accountant_for_seller, seller:)
          expect(subject).to permit(seller_context, comment_context)
        end

        it "grants access to admin" do
          seller_context = SellerContext.new(user: admin_for_seller, seller:)
          expect(subject).to permit(seller_context, comment_context)
        end

        it "grants access to marketing" do
          seller_context = SellerContext.new(user: marketing_for_seller, seller:)
          expect(subject).to permit(seller_context, comment_context)
        end

        it "grants access to support" do
          seller_context = SellerContext.new(user: support_for_seller, seller:)
          expect(subject).to permit(seller_context, comment_context)
        end
      end

      context "when the post is visible to buyer" do
        let(:product) { create(:product) }
        let!(:purchase) { create(:purchase, link: product, purchaser: buyer, created_at: 1.second.ago) }
        let(:comment) { build(:comment, commentable: create(:published_installment, link: product)) }
        let(:seller_context) { SellerContext.new(user: buyer, seller: buyer) }

        it "grants access" do
          expect(subject).to permit(seller_context, comment_context)
        end
      end

      context "when the post is not visible to user" do
        let(:comment) { build(:comment, commentable: create(:published_installment)) }
        let(:seller_context) { SellerContext.new(user: buyer, seller: buyer) }

        it "denies access" do
          expect(subject).not_to permit(seller_context, comment_context)
        end
      end
    end

    context "when user is not logged in" do
      let(:seller_context) { SellerContext.logged_out }

      context "with purchase" do
        let(:comment_context) { CommentContext.new(comment:, commentable: nil, purchase:) }

        it_behaves_like "when purchase is specified"
      end

      context "without purchase" do
        let(:comment) { build(:comment, commentable: create(:published_installment)) }
        let(:comment_context) { CommentContext.new(comment:, commentable: nil, purchase: nil) }

        it "denies access" do
          expect(subject).not_to permit(seller_context, comment_context)
        end
      end
    end
  end

  permissions :update? do
    context "when user is logged in" do
      let(:comment_context) { CommentContext.new(comment:, commentable: nil, purchase: nil) }

      context "when user is author of the comment" do
        let(:comment_author) { create(:user) }
        let(:comment) { create(:comment, author: comment_author) }

        it "grants access" do
          seller_context = SellerContext.new(user: comment_author, seller: comment_author)
          expect(subject).to permit(seller_context, comment_context)
        end
      end

      context "when seller is author of the comment's post" do
        let(:comment) { create(:comment) }

        before do
          comment.commentable.update!(seller:)
        end

        it "denies access to owner" do
          seller_context = SellerContext.new(user: seller, seller:)
          expect(subject).not_to permit(seller_context, comment_context)
        end

        it "denies access to accountant" do
          seller_context = SellerContext.new(user: accountant_for_seller, seller:)
          expect(subject).not_to permit(seller_context, comment_context)
        end

        it "denies access to admin" do
          seller_context = SellerContext.new(user: admin_for_seller, seller:)
          expect(subject).not_to permit(seller_context, comment_context)
        end

        it "denies access to marketing" do
          seller_context = SellerContext.new(user: marketing_for_seller, seller:)
          expect(subject).not_to permit(seller_context, comment_context)
        end

        it "denies access to support" do
          seller_context = SellerContext.new(user: support_for_seller, seller:)
          expect(subject).not_to permit(seller_context, comment_context)
        end
      end

      context "when user is neither author of the comment nor author of the comment's post" do
        let(:visitor) { create(:user) }
        let(:comment) { create(:comment) }
        let(:seller_context) { SellerContext.new(user: visitor, seller: visitor) }

        it "denies access" do
          expect(subject).not_to permit(seller_context, comment_context)
        end
      end
    end

    context "when purchase is specified" do
      let(:seller_context) { SellerContext.logged_out }
      let(:purchase) { create(:purchase, created_at: 1.second.ago) }
      let(:comment) { create(:comment, purchase:) }

      context "when purchase matches associated purchase" do
        let(:comment_context) { CommentContext.new(comment:, commentable: nil, purchase:) }

        it "grants access" do
          expect(subject).to permit(seller_context, comment_context)
        end
      end

      context "when comment does not match associated purchase" do
        let(:other_purchase) { create(:purchase, created_at: 1.second.ago) }
        let(:comment_context) { CommentContext.new(comment:, commentable: nil, purchase: other_purchase) }

        it "denies access" do
          expect(subject).not_to permit(seller_context, comment_context)
        end
      end
    end

    context "when both user and purchase are not specified" do
      let(:seller_context) { SellerContext.logged_out }
      let(:comment) { create(:comment) }
      let(:comment_context) { CommentContext.new(comment:, commentable: nil, purchase: nil) }

      it "denies access" do
        expect(subject).not_to permit(seller_context, comment_context)
      end
    end
  end

  permissions :destroy? do
    context "when user is logged in" do
      let(:comment_context) { CommentContext.new(comment:, commentable: nil, purchase: nil) }

      context "when user is author of the comment" do
        let(:user) { create(:user) }
        let(:comment) { create(:comment, author: user) }
        let(:seller_context) { SellerContext.new(user:, seller: user) }

        it "grants access to owner" do
          expect(subject).to permit(seller_context, comment_context)
        end
      end

      context "when seller is author of the comment's post" do
        let(:comment) { create(:comment) }
        let(:seller_context) { SellerContext.new(user: seller, seller:) }

        before do
          comment.commentable.update!(seller:)
        end

        it "denies access to accountant" do
          seller_context = SellerContext.new(user: accountant_for_seller, seller:)
          expect(subject).not_to permit(seller_context, comment_context)
        end

        it "grants access to owner" do
          seller_context = SellerContext.new(user: seller, seller:)
          expect(subject).to permit(seller_context, comment_context)
        end

        it "grants access to admin" do
          seller_context = SellerContext.new(user: admin_for_seller, seller:)
          expect(subject).to permit(seller_context, comment_context)
        end

        it "grants access to marketing" do
          seller_context = SellerContext.new(user: marketing_for_seller, seller:)
          expect(subject).to permit(seller_context, comment_context)
        end

        it "denies access to support" do
          seller_context = SellerContext.new(user: support_for_seller, seller:)
          expect(subject).not_to permit(seller_context, comment_context)
        end
      end

      context "when user is neither author of the comment nor author of the comment's post" do
        let(:visitor) { create(:user) }
        let(:comment) { create(:comment) }
        let(:seller_context) { SellerContext.new(user: visitor, seller: visitor) }

        it "denies access" do
          expect(subject).not_to permit(seller_context, comment_context)
        end
      end
    end

    context "when purchase is specified" do
      let(:seller_context) { SellerContext.logged_out }
      let(:purchase) { create(:purchase, created_at: 1.second.ago) }
      let(:comment) { create(:comment, purchase:) }

      context "when purchase matches associated purchase" do
        let(:comment_context) { CommentContext.new(comment:, commentable: nil, purchase:) }

        it "grants access" do
          expect(subject).to permit(seller_context, comment_context)
        end
      end

      context "when comment does not match associated purchase" do
        let(:other_purchase) { create(:purchase, created_at: 1.second.ago) }
        let(:comment_context) { CommentContext.new(comment:, commentable: nil, purchase: other_purchase) }

        it "denies access" do
          expect(subject).not_to permit(seller_context, comment_context)
        end
      end
    end

    context "when both user and purchase are not specified" do
      let(:seller_context) { SellerContext.logged_out }
      let(:comment) { create(:comment) }
      let(:comment_context) { CommentContext.new(comment:, commentable: nil, purchase: nil) }

      it "denies access" do
        expect(subject).not_to permit(seller_context, comment_context)
      end
    end
  end
end
