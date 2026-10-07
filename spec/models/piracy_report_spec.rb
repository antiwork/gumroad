# frozen_string_literal: true

require "spec_helper"

describe PiracyReport do
  describe ".normalize_url" do
    it "treats scheme, www, fragment, trailing slash and query order as the same page" do
      expect(described_class.normalize_url("https://WWW.Example.net/a/?b=2&a=1#top")).to eq("example.net/a?a=1&b=2")
      expect(described_class.normalize_url("http://example.net/a?a=1&b=2")).to eq("example.net/a?a=1&b=2")
    end

    it "keeps a non-default port, which can be another server, and drops the default one" do
      expect(described_class.normalize_url("https://example.net:8443/a")).to eq("example.net:8443/a")
      expect(described_class.normalize_url("https://example.net:443/a")).to eq("example.net/a")
      expect(described_class.normalize_url("http://example.net:80/a")).to eq("example.net/a")
    end

    it "treats a fully qualified host with a trailing dot as the same host" do
      expect(described_class.normalize_url("https://example.net./a")).to eq("example.net/a")
      expect(described_class.gumroad_host?("#{ROOT_DOMAIN.split(":").first}.")).to be(true)
    end

    it "returns nil for a URL with credentials before the host" do
      expect(described_class.normalize_url("https://other.example.org@example.net/a")).to be_nil
      expect(described_class.parse_http_url("https://user:pass@example.net/a")).to be_nil
    end

    it "returns nil for anything that is not an http or https URL" do
      expect(described_class.normalize_url("ftp://example.net/a")).to be_nil
      expect(described_class.normalize_url("not a url")).to be_nil
    end
  end

  describe ".gumroad_host?" do
    it "matches Gumroad domains and their subdomains" do
      expect(described_class.gumroad_host?(ROOT_DOMAIN.split(":").first)).to be(true)
      expect(described_class.gumroad_host?("seller.#{ROOT_DOMAIN.split(":").first}")).to be(true)
    end

    it "does not match other hosts, including look-alikes" do
      expect(described_class.gumroad_host?("example.net")).to be(false)
      expect(described_class.gumroad_host?("not#{ROOT_DOMAIN.split(":").first}")).to be(false)
    end
  end

  describe "validations" do
    it "rejects a URL that is not http or https" do
      report = build(:piracy_report, url: "ftp://example.net/a")

      expect(report).not_to be_valid
      expect(report.errors[:url]).to include("must be an http or https URL")
    end

    it "rejects a URL that embeds another URL in its path, query or fragment" do
      [
        "https://example.net/copy/also-remove-https://victim.example/store",
        "https://example.net/copy?next=http%3A%2F%2Fvictim.example",
        "https://example.net/copy#https://victim.example"
      ].each do |url|
        report = build(:piracy_report, url:)

        expect(report).not_to be_valid
        expect(report.errors[:url]).to include("must not contain another URL")
      end
    end

    it "accepts a URL whose path merely contains the letters http" do
      expect(build(:piracy_report, url: "https://example.net/httpd-course/https-guide")).to be_valid
    end

    it "rejects a reported URL longer than the limit" do
      expect(build(:piracy_report, url: "https://example.net/#{"a" * PiracyReport::MAX_REPORTED_URL_LENGTH}")).not_to be_valid
    end

    it "rejects a source outside the allowed list" do
      expect(build(:piracy_report, source: "email")).not_to be_valid
    end

    it "generates a 21 character external id" do
      expect(create(:piracy_report).external_id).to match(/\A[-_0-9a-zA-Z]{21}\z/)
    end

    it "sets the normalized URL digest from the URL" do
      report = create(:piracy_report, url: "https://www.Example.net/design-course/")

      expect(report.normalized_url_digest).to eq(Digest::SHA256.hexdigest("example.net/design-course"))
    end

    it "blocks a second report for the same product and page" do
      report = create(:piracy_report)

      expect do
        create(:piracy_report, product: report.product, seller: report.seller, url: "http://example.net/design-course/")
      end.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "state machine" do
    it "starts in requested and moves to screening" do
      report = create(:piracy_report)
      expect(report.state).to eq("requested")

      report.start_screening!

      expect(report.reload.state).to eq("screening")
    end

    it "moves from screening to awaiting_signature or declined" do
      passed = create(:piracy_report, :screening)
      failed = create(:piracy_report, :screening)

      passed.pass_screening!
      failed.fail_screening!

      expect(passed.reload.state).to eq("awaiting_signature")
      expect(failed.reload.state).to eq("declined")
    end

    it "rejects screening from a state other than requested" do
      report = create(:piracy_report, :screening)

      expect { report.start_screening! }.to raise_error(StateMachines::InvalidTransition)
    end

    it "does not skip screening on the way to awaiting_signature" do
      report = create(:piracy_report)

      expect { report.pass_screening! }.to raise_error(StateMachines::InvalidTransition)
    end
  end

  describe ".blocked_on_recipient and .needs_review" do
    it "splits the reports waiting in screening by the agent's verdict" do
      unscreened = create(:piracy_report, :screening)
      blocked = create(:piracy_report, :screening, screening_verdict: "pass", screened_at: Time.current)
      review = create(:piracy_report, :screening, screening_verdict: "review", screened_at: Time.current)
      declined = create(:piracy_report, :screening, screening_verdict: "fail", screened_at: Time.current).tap(&:fail_screening!)
      passed = create(:piracy_report, :awaiting_signature, screening_verdict: "pass", screened_at: Time.current)

      expect(described_class.blocked_on_recipient).to contain_exactly(blocked)
      expect(described_class.needs_review).to contain_exactly(review)
      expect([blocked, review, unscreened, declined.reload, passed].map(&:blocked_on_recipient?)).to eq([true, false, false, false, false])
      expect([blocked, review, unscreened, declined, passed].map(&:needs_review?)).to eq([false, true, false, false, false])
    end
  end

  describe "#record_signature!" do
    let(:all_confirmations) { PiracyReport::SIGNATURE_CONFIRMATIONS.keys }

    def sign(report, name = "Jane Doe", confirmations: all_confirmations, statement_version: PiracyReport::SIGNATURE_STATEMENT_VERSION, ip: "203.0.113.7")
      report.record_signature!(name, confirmations:, statement_version:, ip:)
    end

    it "signs the report, records what the seller agreed to, and puts the signature in the notice" do
      report = create(:piracy_report, :awaiting_signature)

      travel_to(Time.utc(2026, 10, 7, 12)) { expect(sign(report)).to be(true) }

      signed_text = "Notice text\n\nSigned: /s/ Jane Doe, October 7, 2026\n"
      expect(report.reload).to have_attributes(
        state: "signed",
        signed_by_name: "Jane Doe",
        signed_ip: "203.0.113.7",
        signature_statement_version: PiracyReport::SIGNATURE_STATEMENT_VERSION,
        notice_text: signed_text,
        notice_digest: Digest::SHA256.hexdigest(signed_text)
      )
      expect(report.signed_at).to eq(Time.utc(2026, 10, 7, 12))
    end

    it "refuses to sign unless every confirmation is checked" do
      report = create(:piracy_report, :awaiting_signature)

      expect(sign(report, confirmations: all_confirmations - ["fair_use_considered"])).to be(false)
      expect(sign(report, confirmations: nil)).to be(false)
      expect(report.errors[:base]).to include("Check every confirmation to sign")
      expect(report.reload).to have_attributes(state: "awaiting_signature", notice_text: "Notice text", signed_ip: nil)
    end

    it "trims the name" do
      report = create(:piracy_report, :awaiting_signature)

      sign(report, "  Jane   Doe  ")

      expect(report.reload.signed_by_name).to eq("Jane Doe")
    end

    it "refuses a blank name without changing the state" do
      report = create(:piracy_report, :awaiting_signature)

      expect(sign(report, "   ")).to be(false)
      expect(report.reload.state).to eq("awaiting_signature")
      expect(report.errors[:signed_by_name]).to be_present
    end

    it "refuses to sign when the page showed an older version of the confirmations" do
      report = create(:piracy_report, :awaiting_signature)

      expect(sign(report, statement_version: "2026-01-01")).to be(false)
      expect(report.errors[:base]).to include("The confirmations changed. Reload the page and read them again.")
      expect(report.reload.state).to eq("awaiting_signature")
    end

    it "drops invisible characters, so a name of only zero-width or bidi characters is blank" do
      report = create(:piracy_report, :awaiting_signature)

      expect(sign(report, "\u200B\u202E")).to be(false)
      expect(report.errors[:signed_by_name]).to be_present

      other = create(:piracy_report, :awaiting_signature)
      expect(sign(other, "Jane\u202E Doe")).to be(true)
      expect(other.reload.signed_by_name).to eq("Jane Doe")
    end

    it "refuses a name longer than the column" do
      report = create(:piracy_report, :awaiting_signature)

      expect(sign(report, "a" * 256)).to be(false)
      expect(report.reload.state).to eq("awaiting_signature")
      expect(report.errors[:signed_by_name]).to include("is too long")
    end

    it "refuses a report that is not waiting for a signature" do
      report = create(:piracy_report, :screening)

      expect(sign(report)).to be(false)
      expect(report.reload.state).to eq("screening")
      expect(report.errors[:base]).to include("This report is not ready to sign")
    end

    it "cannot be signed twice" do
      report = create(:piracy_report, :awaiting_signature)
      sign(report)

      expect(sign(report, "Someone Else")).to be(false)
      expect(report.reload.signed_by_name).to eq("Jane Doe")
    end
  end

  describe "the gate on sending" do
    # The state machine can move the row to `sent` on its own, so the gate has to be a validation.
    def mark_sent(report)
      report.assign_attributes(state: "sent", sent_at: Time.current, sent_to_email: report.recipient_email)
      report
    end

    it "refuses to save as sent over text that changed after it was signed" do
      report = create(:piracy_report, :signed)
      report.update_columns(notice_text: "Notice text\n\nSigned: /s/ Someone Else, January 1, 2026\n")

      expect(mark_sent(report)).not_to be_valid
      expect(report.errors[:base]).to include("The notice changed after it was signed")
    end

    it "refuses to save as sent without a signature" do
      report = create(:piracy_report, :signed, signed_at: nil, signed_by_name: nil, signature_statement_version: nil)

      expect(mark_sent(report)).not_to be_valid
      expect(report.errors[:base]).to include("The notice was not signed")
    end

    it "refuses to save as sent under different confirmations" do
      report = create(:piracy_report, :signed, signature_statement_version: "2026-01-01")

      expect(mark_sent(report)).not_to be_valid
      expect(report.errors[:base]).to include("The notice was signed under different confirmations")
    end

    it "accepts the signed text and gives the report a reply address of its own" do
      report = create(:piracy_report, :sent)

      expect(report.reply_token).to be_present
      expect(report.reply_to_address).to eq("support+#{report.reply_token}@#{DEFAULT_EMAIL_DOMAIN}")
    end
  end
end
