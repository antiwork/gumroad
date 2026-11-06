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

  it "screens past named entities, invisible characters and whitespace runs" do
    expect(screen("Gum&shy;road Security Alert: log in to continue")).to be_nil
    expect(screen("Gum\u200Broad Security Alert: log in to continue")).to be_nil
    expect(screen("Gumroad Security\u00A0 Alert: log in to continue")).to be_nil
    expect(screen("Gumroad<br>Security<br>alert: log in to continue")).to be_nil
  end

  it "holds a public-files.gumroad.com link hidden in an href" do
    expect(screen(%(Your files: <a href="https://public-files.gumroad.com/a.html">Download</a>))).to be_nil
    expect(screen(%(<a href="https://public-files%2Egumroad.com/a.html">Download</a>))).to be_nil
    expect(screen(%(<a href="https://ｐｕｂｌｉｃ-files\u3002gum&shy;road．com/a.html">Download</a>))).to be_nil
  end

  it "drops a blocklisted link hidden in an href" do
    allow(ContentModeration::Strategies::BlocklistStrategy).to receive(:yaml_words).and_return(["phishword"])
    expect(screen(%(<a href="https://phishword.example/a">Download</a>))).to be_nil
  end

  it "passes a clean link with a malformed escape" do
    expect(screen(%(<a href="https://example.com/%FF">Download</a>))).to be_present
  end

  it "still drops the text when queueing the admin note fails" do
    allow(ContentModerationAdminCommentJob).to receive(:perform_async).and_raise(RedisClient::CannotConnectError)
    expect(screen("see https://public-files.gumroad.com/x.html")).to be_nil
  end
end
