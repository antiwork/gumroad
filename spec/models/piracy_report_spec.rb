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

  describe ".blocked_on_recipient" do
    it "finds only the reports that were screened and stayed in screening" do
      unscreened = create(:piracy_report, :screening)
      blocked = create(:piracy_report, :screening, screened_at: Time.current)
      declined = create(:piracy_report, :screening, screened_at: Time.current).tap(&:fail_screening!)
      passed = create(:piracy_report, :awaiting_signature, screened_at: Time.current)

      expect(described_class.blocked_on_recipient).to contain_exactly(blocked)
      expect(blocked.blocked_on_recipient?).to be(true)
      expect(unscreened.blocked_on_recipient?).to be(false)
      expect(declined.reload.blocked_on_recipient?).to be(false)
      expect(passed.blocked_on_recipient?).to be(false)
    end
  end

  describe "#record_signature!" do
    it "signs the report and keeps the notice it signed" do
      report = create(:piracy_report, :awaiting_signature)

      expect(report.record_signature!("Jane Doe")).to be(true)
      expect(report.reload).to have_attributes(
        state: "signed",
        signed_by_name: "Jane Doe",
        notice_text: "Notice text",
        notice_digest: Digest::SHA256.hexdigest("Notice text")
      )
      expect(report.signed_at).to be_present
    end

    it "trims the name" do
      report = create(:piracy_report, :awaiting_signature)

      report.record_signature!("  Jane   Doe  ")

      expect(report.reload.signed_by_name).to eq("Jane Doe")
    end

    it "refuses a blank name without changing the state" do
      report = create(:piracy_report, :awaiting_signature)

      expect(report.record_signature!("   ")).to be(false)
      expect(report.reload.state).to eq("awaiting_signature")
      expect(report.errors[:signed_by_name]).to be_present
    end

    it "refuses a name longer than the column" do
      report = create(:piracy_report, :awaiting_signature)

      expect(report.record_signature!("a" * 256)).to be(false)
      expect(report.reload.state).to eq("awaiting_signature")
      expect(report.errors[:signed_by_name]).to include("is too long")
    end

    it "refuses a report that is not waiting for a signature" do
      report = create(:piracy_report, :screening)

      expect(report.record_signature!("Jane Doe")).to be(false)
      expect(report.reload.state).to eq("screening")
      expect(report.errors[:base]).to include("This report is not ready to sign")
    end

    it "cannot be signed twice" do
      report = create(:piracy_report, :awaiting_signature)
      report.record_signature!("Jane Doe")

      expect(report.record_signature!("Someone Else")).to be(false)
      expect(report.reload.signed_by_name).to eq("Jane Doe")
    end
  end
end
