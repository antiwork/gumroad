# frozen_string_literal: true

require "spec_helper"

describe ContentModeration::SellerMailTextGuard do
  let(:seller) { create(:user) }

  def screen(text) = described_class.screen(text, seller:, source: "test")

  it "returns clean text unchanged without a note" do
    expect(ContentModerationAdminCommentJob).not_to receive(:perform_async)
    expect(screen("Thanks for buying! Join my Discord at https://example.com")).to eq("Thanks for buying! Join my Discord at https://example.com")
  end

  it "passes blank text through" do
    expect(screen(nil)).to be_nil
    expect(screen("")).to be_nil
  end

  it "drops text the blocklist flags and notes the seller" do
    allow(ContentModeration::Strategies::BlocklistStrategy).to receive(:yaml_words).and_return(["phishword"])
    expect(ContentModerationAdminCommentJob).to receive(:perform_async).with(seller.id, /not sent\): blocklist: Matched blocked word: phishword/)
    expect(screen("click phishword now")).to be_nil
  end

  it "holds text that links to public-files.gumroad.com" do
    expect(ContentModerationAdminCommentJob).to receive(:perform_async).with(seller.id, /public-files\.gumroad\.com/)
    expect(screen("see https://public-files.gumroad.com/x/y.html")).to be_nil
  end

  [
    "Gumroad Security Alert: log in to continue",
    "Your Gumroad payout is on hold, verify your account today",
    "Action required: confirm your payout method on Gumroad",
  ].each do |text|
    it "holds text posing as a Gumroad notice: #{text}" do
      expect(ContentModerationAdminCommentJob).to receive(:perform_async).with(seller.id, /poses as a Gumroad security or payout notice/)
      expect(screen(text)).to be_nil
    end
  end

  it "does not hold ordinary mentions of Gumroad or security" do
    expect(screen("Thanks for buying on Gumroad! Security tips are in the PDF.")).to be_present
  end

  it "screens the text recipients actually read, past split tags" do
    expect(screen("Gum<b></b>road Sec<b></b>urity Alert: ver<b></b>ify your acc<b></b>ount")).to be_nil
    expect(screen("see https://public-files.gum<i></i>road.com/a.html")).to be_nil
  end

  it "still drops the text when queueing the admin note fails" do
    allow(ContentModerationAdminCommentJob).to receive(:perform_async).and_raise(RedisClient::CannotConnectError)
    expect(screen("see https://public-files.gumroad.com/x.html")).to be_nil
  end
end
