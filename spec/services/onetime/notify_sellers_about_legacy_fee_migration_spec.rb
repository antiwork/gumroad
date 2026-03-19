# frozen_string_literal: true

require "spec_helper"

describe Onetime::NotifySellersAboutLegacyFeeMigration do
  before do
    @seller_1 = create(:user)
    @seller_2 = create(:user)
    @deleted_seller = create(:user, :deleted)
    @suspended_seller = create(:tos_user)
    @no_email_seller = create(:user)
    @no_email_seller.update_column(:email, "")
  end

  after do
    $redis.del(described_class::LAST_PROCESSED_USER_ID_KEY)
  end

  it "enqueues the email only for eligible sellers" do
    seller_ids = [@seller_1.id, @seller_2.id, @deleted_seller.id, @suspended_seller.id, @no_email_seller.id]

    expect do
      described_class.new(seller_ids:).process
    end.to have_enqueued_mail(OneOffMailer, :email).with(email: @seller_1.form_email, subject: described_class::SUBJECT, body: described_class::BODY, reply_to: ApplicationMailer::SUPPORT_EMAIL).once
       .and have_enqueued_mail(OneOffMailer, :email).with(email: @seller_2.form_email, subject: described_class::SUBJECT, body: described_class::BODY, reply_to: ApplicationMailer::SUPPORT_EMAIL).once
       .and have_enqueued_mail(OneOffMailer, :email).exactly(2).times
  end

  it "returns the list of emailed seller IDs" do
    service = described_class.new(seller_ids: [@seller_1.id, @seller_2.id, @no_email_seller.id])
    result = service.process
    expect(result).to contain_exactly(@seller_1.id, @seller_2.id)
    expect(service.emailed_user_ids).to contain_exactly(@seller_1.id, @seller_2.id)
  end

  it "tracks the last visited user ID in Redis" do
    all_ids = [@seller_1.id, @seller_2.id].sort
    described_class.new(seller_ids: all_ids).process
    expect($redis.get(described_class::LAST_PROCESSED_USER_ID_KEY).to_i).to eq(all_ids.last)
  end

  it "advances the checkpoint past blank-email users" do
    described_class.new(seller_ids: [@no_email_seller.id]).process
    expect($redis.get(described_class::LAST_PROCESSED_USER_ID_KEY).to_i).to eq(@no_email_seller.id)
  end

  context "when re-run after partial completion" do
    it "skips already-processed users" do
      sorted_ids = [@seller_1.id, @seller_2.id].sort
      first_id = sorted_ids.first
      second_id = sorted_ids.last

      $redis.set(described_class::LAST_PROCESSED_USER_ID_KEY, first_id)

      second_seller = User.find(second_id)

      expect do
        described_class.new(seller_ids: sorted_ids).process
      end.to have_enqueued_mail(OneOffMailer, :email).with(hash_including(email: second_seller.form_email)).once
         .and have_enqueued_mail(OneOffMailer, :email).exactly(1).times
    end
  end

  it "normalizes string IDs to integers" do
    service = described_class.new(seller_ids: [@seller_1.id.to_s, @seller_2.id.to_s])
    expect(service.seller_ids).to eq([@seller_1.id, @seller_2.id].sort)
  end

  it "handles non-existent IDs gracefully" do
    expect do
      described_class.new(seller_ids: [0, -1, 999_999_999]).process
    end.to_not have_enqueued_mail(OneOffMailer, :email)
  end

  describe ".reset_last_processed_user_id" do
    it "clears the Redis checkpoint" do
      $redis.set(described_class::LAST_PROCESSED_USER_ID_KEY, 123)
      described_class.reset_last_processed_user_id
      expect($redis.get(described_class::LAST_PROCESSED_USER_ID_KEY)).to be_nil
    end
  end
end
