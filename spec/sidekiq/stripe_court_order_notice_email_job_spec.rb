# frozen_string_literal: true

require "spec_helper"

describe StripeCourtOrderNoticeEmailJob do
  let(:seller) { create(:user, email: "seller@example.com") }
  let(:comment) { create(:comment, commentable: seller, comment_type: Comment::COMMENT_TYPE_NOTE, idempotency_key: "stripe_court_order_notice:test-0003") }

  it "emails the seller when the notice comment exists" do
    described_class.new.perform(seller.id, comment.id, "Example Legal LLP", "notices@example.com")

    mail = ActionMailer::Base.deliveries.sole
    expect(mail.to).to eq(["seller@example.com"])
    expect(mail.subject).to eq("Important notice regarding your Gumroad payment account")
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

  it "raises a rejected send so Sidekiq retries it" do
    allow_any_instance_of(Mail::Message).to receive(:deliver).and_raise(Net::SMTPFatalError.new("550 rejected"))

    expect do
      described_class.new.perform(seller.id, comment.id, "Example Legal LLP", "notices@example.com")
    end.to raise_error(Net::SMTPFatalError)
  end
end
