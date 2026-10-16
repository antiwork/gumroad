# frozen_string_literal: true

require "spec_helper"

describe "mysql2 proxy Stripe restraint notice routing" do
  include_context "real mysql2 proxy pools"

  it "checks the notice and addresses the email from the primary, not a lagging replica" do
    seller, comment = primary_setup do
      user = create(:user, email: "old-seller@example.com")
      [user, create(:comment, commentable: user, comment_type: Comment::COMMENT_TYPE_NOTE)]
    end
    replicate_record(seller)
    primary_setup { seller.update_column(:email, "seller@example.com") }
    expect(serving_pool).to eq("replica")

    reads = record_serving_reads do
      StripeRestraintNoticeEmailJob.new.perform(seller.id, comment.id, "Example Legal LLP", "notices@example.com")
    end

    expect(ActionMailer::Base.deliveries.sole.to).to eq(["seller@example.com"])
    notice_reads = reads.select { |sql, _| sql.include?("`users`") || sql.include?("`comments`") }
    expect(notice_reads).not_to be_empty
    expect(notice_reads.map(&:last).uniq).to eq(["primary"])
  end
end
