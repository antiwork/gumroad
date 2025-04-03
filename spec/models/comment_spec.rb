# frozen_string_literal: true

require "spec_helper"

describe Comment do
  describe "validations" do
    describe "content length" do
      context "when content is within the configured character limit" do
        subject(:comment) { build(:comment, commentable: create(:published_installment), content: "a" * 10_000) }

        it "marks the comment as valid" do
          expect(comment).to be_valid
        end
      end

      context "when content is bigger than the configured character limit" do
        subject(:comment) { build(:comment, commentable: create(:published_installment), content: "a" * 10_001) }

        it "marks the comment as invalid" do
          expect(comment).to be_invalid
          expect(comment.errors.full_messages).to match_array(["Content is too long (maximum is 10000 characters)"])
        end
      end
    end

    describe "content_cannot_contain_adult_keywords" do
      context "when content contains an adult keyword" do
        context "when the author is not a team member" do
          subject(:comment) { build(:comment, commentable: create(:published_installment), content: "nsfw content") }

          it "marks the comment as invalid" do
            expect(comment).to be_invalid
            expect(comment.errors.full_messages).to match_array(["Adult keywords are not allowed"])
          end
        end

        context "when the author is a team member" do
          subject(:comment) { build(:comment, commentable: create(:published_installment), content: "nsfw content", author: create(:user, is_team_member: true)) }

          it "marks the comment as valid" do
            expect(comment).to be_valid
          end
        end

        context "when author name is iffy" do
          subject(:comment) { build(:comment, commentable: create(:published_installment), author: nil, content: "nsfw content", author_name: "iffy") }

          it "marks the comment as valid" do
            expect(comment).to be_valid
          end
        end
      end

      context "when content does not contain adult keywords" do
        subject(:comment) { build(:comment, commentable: create(:published_installment)) }

        it "marks the comment as valid" do
          expect(comment).to be_valid
        end
      end
    end

    describe "depth numericality" do
      let(:commentable) { create(:published_installment) }
      let(:root_comment) { create(:comment, commentable:) }
      let(:reply1) { create(:comment, parent: root_comment, commentable:) }
      let(:reply_at_depth_2) { create(:comment, parent: reply1, commentable:) }
      let(:reply_at_depth_3) { create(:comment, parent: reply_at_depth_2, commentable:) }
      let(:reply_at_depth_4) { create(:comment, parent: reply_at_depth_3, commentable:) }

      context "when a comment exceeds maximum allowed depth" do
        subject(:reply_at_depth_5) { build(:comment, parent: reply_at_depth_4, commentable:) }

        it "marks the comment as invalid" do
          expect(reply_at_depth_5).to be_invalid
          expect(reply_at_depth_5.errors.full_messages).to match_array(["Depth must be less than or equal to 4"])
        end
      end

      context "when depth is set manually" do
        subject(:comment) { build(:comment, commentable:, parent: root_comment, ancestry_depth: 3) }

        it "marks the comment as valid and sets the depth according to its actual position in its ancestry tree" do
          expect(comment).to be_valid
          expect(comment.depth).to eq(1)
        end
      end
    end
  end

  describe "callbacks" do
    describe "before_save" do
      describe "#trim_extra_newlines" do
        subject(:comment) { build(:comment, commentable: create(:published_installment)) }

        it "trims unnecessary additional newlines" do
          comment.content = "\n       Here are things -\n\n1. One\n2. Two\n\t2.1 Two.One\n\t\t2.1.1 Two.One.One\n\t\t2.1.2 Two.One.Two\n\t\t\t2.1.2.1 Two.One.Two.One\n\t2.2 Two.Two\n3. Three\n\n\n\n\nWhat do you think?\n\n   "

          expect do
            comment.save!
          end.to change { comment.content }.to("Here are things -\n\n1. One\n2. Two\n\t2.1 Two.One\n\t\t2.1.1 Two.One.One\n\t\t2.1.2 Two.One.Two\n\t\t\t2.1.2.1 Two.One.Two.One\n\t2.2 Two.Two\n3. Three\n\nWhat do you think?")
        end
      end
    end

    describe "after_commit" do
      describe "#notify_seller_of_new_comment" do
        let(:seller) { create(:named_seller) }
        let(:commentable) { create(:published_installment, seller:) }
        let(:comment) { build(:comment, commentable:, comment_type: Comment::COMMENT_TYPE_USER_SUBMITTED) }

        context "when a new comment is added" do
          context "when it is not a user submitted comment" do
            before do
              comment.comment_type = :flagged
            end

            it "does not send a notification to the seller" do
              expect do
                comment.save!
              end.to_not have_enqueued_mail(CommentMailer, :notify_seller_of_new_comment)
            end
          end

          context "when it is not a root comment" do
            before do
              comment.parent = create(:comment, commentable:)
            end

            it "does not send a notification to the seller" do
              expect do
                comment.save!
              end.to_not have_enqueued_mail(CommentMailer, :notify_seller_of_new_comment)
            end
          end

          context "when it is authored by the seller" do
            before do
              comment.author = seller
            end

            it "does not send a notification to the seller" do
              expect do
                comment.save!
              end.to_not have_enqueued_mail(CommentMailer, :notify_seller_of_new_comment)
            end
          end

          context "when the seller has opted out of comments email notifications" do
            before do
              seller.update!(disable_comments_email: true)
            end

            it "does not send a notification to the seller" do
              expect do
                comment.save!
              end.to_not have_enqueued_mail(CommentMailer, :notify_seller_of_new_comment)
            end
          end

          it "emails the seller" do
            expect do
              comment.save!
            end.to have_enqueued_mail(CommentMailer, :notify_seller_of_new_comment)
          end
        end

        context "when a comment gets updated" do
          let(:comment) { create(:comment, commentable:) }

          it "does not send a notification to the seller" do
            comment.update!(content: "new content")
          end
        end
      end
    end
  end

  describe "#mark_subtree_deleted!" do
    let(:commentable) { create(:published_installment) }
    let(:root_comment) { create(:comment, commentable:) }
    let!(:reply1) { create(:comment, parent: root_comment, commentable:) }
    let!(:reply2) { create(:comment, parent: root_comment, commentable:) }
    let!(:reply_at_depth_2) { create(:comment, parent: reply1, commentable:) }
    let!(:reply_at_depth_3) { create(:comment, parent: reply_at_depth_2, commentable:, deleted_at: 1.minute.ago) }
    let!(:reply_at_depth_4) { create(:comment, parent: reply_at_depth_3, commentable:) }

    it "soft deletes the comment along with its descendants" do
      expect do
        expect do
          expect do
            expect do
              reply1.mark_subtree_deleted!
            end.to change { reply1.reload.alive? }.from(true).to(false)
            .and change { reply_at_depth_2.reload.alive? }.from(true).to(false)
            .and change { reply_at_depth_4.reload.alive? }.from(true).to(false)
          end.to_not change { root_comment.reload.alive? }
        end.to_not change { reply2.reload.alive? }
      end.to_not change { reply_at_depth_3.reload.alive? }

      expect(root_comment.was_alive_before_marking_subtree_deleted).to be_nil
      expect(reply1.was_alive_before_marking_subtree_deleted).to be_nil
      expect(reply2.was_alive_before_marking_subtree_deleted).to be_nil
      expect(reply_at_depth_2.was_alive_before_marking_subtree_deleted).to eq(true)
      expect(reply_at_depth_3.was_alive_before_marking_subtree_deleted).to be_nil
      expect(reply_at_depth_4.was_alive_before_marking_subtree_deleted).to eq(true)
    end
  end

  describe "#mark_subtree_undeleted!" do
    let(:commentable) { create(:published_installment) }
    let(:root_comment) { create(:comment, commentable:) }
    let!(:reply1) { create(:comment, parent: root_comment, commentable:) }
    let!(:reply2) { create(:comment, parent: root_comment, commentable:) }
    let!(:reply_at_depth_2) { create(:comment, parent: reply1, commentable:) }
    let!(:reply_at_depth_3) { create(:comment, parent: reply_at_depth_2, commentable:) }

    before do
      reply1.mark_subtree_deleted!
    end

    it "marks the comment and its descendants undeleted" do
      expect do
        expect do
          expect do
            reply1.mark_subtree_undeleted!
          end.to change { reply1.reload.alive? }.from(false).to(true)
          .and change { reply_at_depth_2.reload.alive? }.from(false).to(true)
          .and change { reply_at_depth_3.reload.alive? }.from(false).to(true)
        end.to_not change { root_comment.reload.alive? }
      end.to_not change { reply2.reload.alive? }

      expect(Comment.all.map(&:was_alive_before_marking_subtree_deleted).uniq).to match_array([nil])
    end
  end
end
