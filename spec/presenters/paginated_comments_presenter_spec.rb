# frozen_string_literal: true

describe PaginatedCommentsPresenter do
  describe "#result" do
    let(:product) { create(:product) }
    let(:post) { create(:published_installment, link: product, installment_type: "product", shown_on_profile: true) }
    let(:logged_in_user) { create(:user) }
    let(:logged_in_seller) { logged_in_user }
    let(:pundit_user) { SellerContext.new(user: logged_in_user, seller: logged_in_seller) }
    let!(:comment1) { create(:comment, commentable: post, author: logged_in_user, created_at: 1.minute.ago) }
    let!(:comment2) { create(:comment, commentable: post) }
    let!(:comment_on_another_post) { create(:comment) }
    let(:purchase) { nil }
    let(:options) { {} }
    let(:presenter) { described_class.new(pundit_user:, commentable: post, purchase:, options:) }

    before do
      stub_const("#{described_class}::COMMENTS_PER_PAGE", 1)
    end

    context "when 'page' option is not specified" do
      it "returns paginated comments for the first page along with pagination metadata" do
        result = presenter.result

        expect(result[:comments].length).to eq(1)
        expect(result[:comments].first[:id]).to eq(comment1.external_id)
        expect(result[:pagination]).to eq(count: 2, items: 1, pages: 2, page: 1, next: 2, prev: nil, last: 2)
      end
    end

    context "when 'page' option is specified" do
      let(:options) { { page: 2 } }

      it "returns paginated comments for the specified page along with pagination metadata" do
        result = presenter.result

        expect(result[:comments].length).to eq(1)
        expect(result[:comments].first[:id]).to eq(comment2.external_id)
        expect(result[:pagination]).to eq(count: 2, items: 1, pages: 2, page: 2, next: nil, prev: 1, last: 2)
      end
    end

    context "when the specified 'page' option is an overflowing page number" do
      let(:options) { { page: 3 } }

      it "raises an exception" do
        expect do
          presenter.result
        end.to raise_error(Pagy::OverflowError)
      end
    end

    context "when there exists comments with nested replies" do
      let!(:reply1_to_comment1) { create(:comment, parent: comment1, commentable: post) }
      let!(:reply1_to_comment2) { create(:comment, parent: comment2, commentable: post) }
      let!(:reply_at_depth_2) { create(:comment, parent: reply1_to_comment2, commentable: post) }
      let!(:reply_at_depth_3) { create(:comment, parent: reply_at_depth_2, commentable: post) }
      let!(:reply_at_depth_4) { create(:comment, parent: reply_at_depth_3, commentable: post) }
      let(:options) { { page: 2 } }

      it "always returns count of all root comments and their descendants irrespective of specified 'page' option" do
        result = presenter.result

        expect(result[:comments].length).to eq(5)
        expect(result[:count]).to eq(7)
      end

      context "when 'page' option is specified with value of 1" do
        let(:options) { { page: 1 } }

        it "returns paginated roots comments for the first page along with their descendants" do
          result = presenter.result

          expect(result[:comments].length).to eq(2)
          expect(result[:comments].pluck(:id)).to match_array([comment1.external_id, reply1_to_comment1.external_id])
        end
      end

      context "when 'page' option is specified with value of 2" do
        let(:options) { { page: 2 } }

        it "returns paginated roots comments for the second page along with their descendants" do
          result = presenter.result

          expect(result[:comments].length).to eq(5)
          expect(result[:comments].pluck(:id)).to match_array([
                                                                comment2.external_id,
                                                                reply1_to_comment2.external_id,
                                                                reply_at_depth_2.external_id,
                                                                reply_at_depth_3.external_id,
                                                                reply_at_depth_4.external_id
                                                              ])
        end
      end
    end
  end
end
