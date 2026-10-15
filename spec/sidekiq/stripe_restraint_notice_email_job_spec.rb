# frozen_string_literal: true

require "spec_helper"

describe StripeRestraintNoticeEmailJob do
  let(:seller) { create(:user, email: "seller@example.com") }
  let(:comment) { create(:comment, commentable: seller, comment_type: Comment::COMMENT_TYPE_NOTE, idempotency_key: "stripe_restraint_notice:test-0003") }

  def perform
    described_class.new.perform(seller.id, comment.id, "Example Legal LLP", "notices@example.com")
  end

  def accepted_markers
    seller.comments.where(idempotency_key: "stripe_restraint_notice_accepted:#{comment.id}")
  end

  it "emails the seller and records the mail service's acceptance" do
    perform

    mail = ActionMailer::Base.deliveries.sole
    expect(mail.to).to eq(["seller@example.com"])
    expect(mail.subject).to eq("Important notice regarding your Gumroad payment account")
    expect(accepted_markers.sole).to have_attributes(content: described_class::ACCEPTED_CONTENT, author_id: comment.author_id)
  end

  it "sends nothing for a notice that was already accepted" do
    perform
    perform

    expect(ActionMailer::Base.deliveries.size).to eq(1)
    expect(accepted_markers.count).to eq(1)
  end

  it "sends nothing when the notice comment was rolled back" do
    described_class.new.perform(seller.id, Comment.maximum(:id).to_i + 1, "Example Legal LLP", "notices@example.com")

    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it "sends nothing when the comment belongs to another user" do
    other_comment = create(:comment, commentable: create(:user), comment_type: Comment::COMMENT_TYPE_NOTE)

    described_class.new.perform(seller.id, other_comment.id, "Example Legal LLP", "notices@example.com")

    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it "raises a rejected send so Sidekiq retries it, and records no acceptance" do
    allow_any_instance_of(Mail::Message).to receive(:deliver).and_raise(Net::SMTPFatalError.new("550 rejected"))

    expect { perform }.to raise_error(Net::SMTPFatalError)
    expect(accepted_markers).to be_empty
  end

  it "raises instead of claiming acceptance when the marker does not save" do
    unsaved = seller.comments.new
    unsaved.errors.add(:base, "Adult keywords are not allowed")
    allow_any_instance_of(User::CreateAdminCommentService).to receive(:perform).and_return(unsaved)

    expect { perform }.to raise_error(RuntimeError, /was sent but its acceptance was not recorded/)
    expect(accepted_markers).to be_empty
  end
end
