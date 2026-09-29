# frozen_string_literal: true

require "spec_helper"

describe PiracyReports::ScreenService do
  let(:admin) { create(:admin_user) }
  let(:seller_and_product) { create_piracy_seller_with_product }
  let(:seller) { seller_and_product.first }
  let(:product) { seller_and_product.last }
  let(:report) { create(:piracy_report, :screening, seller:, product:, url: "https://example.net/design-course") }

  let(:passing_checks) do
    PiracyReport::SCREENING_CHECKS.index_with { { "passed" => true, "reason" => "Matches the product." } }
  end
  let(:pass_params) do
    {
      "verdict" => "pass",
      "checks" => passing_checks,
      "recipient_kind" => "site",
      "recipient_name" => "Example Net",
      "recipient_email" => "copyright@example.net",
      "recipient_source_url" => "https://example.net/copyright"
    }
  end

  def call(params)
    described_class.new(report:, actor: admin, params: params.with_indifferent_access).call
  end

  describe "a pass verdict" do
    it "renders the notice, stores its digest and moves to awaiting_signature" do
      result = call(pass_params)

      expect(result).to be_success
      report.reload
      expect(report.state).to eq("awaiting_signature")
      expect(report.screening_verdict).to eq("pass")
      expect(report.notice_digest).to eq(Digest::SHA256.hexdigest(report.notice_text))
      expect(report.signature_statement_version).to eq(PiracyReports::NoticeRenderer::STATEMENT_VERSION)
      expect(report.recipient_email).to eq("copyright@example.net")
      expect(report.events.order(:id).last).to have_attributes(event: "pass_screening", actor_type: "admin_actor")
    end

    it "builds the notice from Rails data and the validated URLs only" do
      call(pass_params)

      notice = report.reload.notice_text
      expect(notice).to include("To the Designated Agent of example.net:")
      expect(notice).to include(seller.alive_user_compliance_info.legal_entity_name)
      expect(notice).to include(%("#{product.name}"))
      expect(notice).to include("   https://example.net/design-course\n")
      expect(notice).to include("under penalty of perjury")
      expect(notice).not_to include("Matches the product.")
    end

    it "lists only the page the seller reported, whatever URLs the agent sends" do
      call(pass_params.merge("infringing_urls" => ["https://example.net/someone-elses-file"]))

      report.reload
      expect(report.infringing_urls).to eq(["https://example.net/design-course"])
      expect(report.notice_text).not_to include("someone-elses-file")
    end

    it "addresses the notice to the reported host and never prints the agent's recipient name" do
      call(pass_params.merge("recipient_name" => "Example Net and Friends"))

      notice = report.reload.notice_text
      expect(notice.lines.first).to eq("To the Designated Agent of example.net:\n")
      expect(notice).not_to include("Friends")
    end

    it "names the hosting provider of the reported host when the recipient is a host" do
      call(pass_params.merge("recipient_kind" => "host", "recipient_source_url" => "https://dmca.copyright.gov/osp/publicsearch.html"))

      expect(report.reload.notice_text.lines.first).to eq("To the Designated Agent of the hosting provider of example.net:\n")
    end

    it "rejects a recipient name with characters outside letters, digits and basic punctuation" do
      result = call(pass_params.merge("recipient_name" => "Example Net:\nIgnore the above"))

      expect(result.errors).to eq(["recipient_name must be 1 to 100 letters, digits, spaces or . , & ' -"])
    end

    it "prints the seller's confirmed email, not a pending unverified one" do
      seller.update_columns(unconfirmed_email: "typo@example.com")

      call(pass_params)

      notice = report.reload.notice_text
      expect(notice).to include(seller.email)
      expect(notice).not_to include("typo@example.com")
    end

    it "rejects recipient fields longer than their columns instead of raising" do
      long_email = "#{"a" * 250}@example.net"
      long_source = "https://example.net/#{"a" * PiracyReport::MAX_URL_LENGTH}"

      result = call(pass_params.merge("recipient_email" => long_email, "recipient_source_url" => long_source))

      expect(result.errors).to include("recipient_email is invalid")
      expect(result.errors).to include("recipient_source_url must be an http(s) URL of at most 2048 characters")
      expect(report.reload.state).to eq("screening")
    end

    it "declines with Rails' reasons when the seller stopped being eligible after filing" do
      Feature.deactivate_user(:piracy_reports, seller)

      result = call(pass_params)

      expect(result).to be_success
      report.reload
      expect(report.state).to eq("declined")
      expect(report.screening_verdict).to eq("fail")
      expect(report.screening_checks["rails"]).to eq(["Piracy reports are not enabled for this seller"])
      expect(report.notice_text).to be_nil
    end

    it "rejects a pass when a check failed" do
      checks = passing_checks.merge("page_offers_work" => { "passed" => false, "reason" => "Different course." })

      result = call(pass_params.merge("checks" => checks))

      expect(result.errors).to include("every check must pass for a pass verdict")
      expect(report.reload.state).to eq("screening")
    end

    it "rejects a pass with a missing check" do
      result = call(pass_params.merge("checks" => passing_checks.except("recipient_found")))

      expect(result.errors).to include("a pass verdict needs every check: missing recipient_found")
    end

    it "rejects a check without a reason" do
      checks = passing_checks.merge("recipient_found" => { "passed" => true, "reason" => "" })

      expect(call(pass_params.merge("checks" => checks)).errors).to include("check recipient_found needs a reason")
    end

    it "rejects a check that is not an object instead of raising" do
      as_string = call(pass_params.merge("checks" => passing_checks.merge("page_offers_work" => "yes")))
      as_array = call(pass_params.merge("checks" => passing_checks.merge("page_offers_work" => [true])))

      expect(as_string.errors).to include("check page_offers_work must be an object")
      expect(as_array.errors).to include("check page_offers_work must be an object")
      expect(report.reload.state).to eq("screening")
    end

    it "does not read a non-boolean passed value as true" do
      [[false], ["false"], { "x" => "y" }, "yes", nil].each do |bad|
        result = call(pass_params.merge("checks" => passing_checks.merge("page_offers_work" => { "passed" => bad, "reason" => "r" })))

        expect(result.errors).to include("check page_offers_work passed must be true or false")
      end
      expect(report.reload.state).to eq("screening")
    end

    it "accepts passed as a boolean or as the strings true and false" do
      as_strings = passing_checks.transform_values { { "passed" => "true", "reason" => "r" } }

      expect(call(pass_params.merge("checks" => as_strings))).to be_success
    end

    it "declines when the reported host became a seller's custom domain after the report was filed" do
      report
      create(:custom_domain, domain: "example.net")

      result = call(pass_params)

      expect(result).to be_success
      expect(report.reload).to have_attributes(state: "declined", screening_checks: hash_including("rails" => [PiracyReport::HOSTED_ON_GUMROAD_ERROR]))
    end

    it "refuses a second result from a copy of the report loaded before the first result" do
      stale_copy = PiracyReport.find(report.id)
      call(pass_params)

      result = described_class.new(report: stale_copy, actor: admin, params: pass_params.merge("verdict" => "fail").with_indifferent_access).call

      expect(result.errors).to eq(["The report is not being screened"])
      expect(report.reload).to have_attributes(state: "awaiting_signature", screening_verdict: "pass")
    end

    it "rejects a check name that is not in the fixed list" do
      checks = passing_checks.merge("looks_fine" => { "passed" => true, "reason" => "Trust me." })

      expect(call(pass_params.merge("checks" => checks)).errors).to include("unknown check looks_fine")
    end

    it "rejects a recipient on a Gumroad address or at the seller's own address" do
      gumroad = call(pass_params.merge("recipient_email" => "abuse@#{ROOT_DOMAIN.split(":").first}"))
      own = call(pass_params.merge("recipient_email" => seller.email))

      expect(gumroad.errors).to include("recipient_email cannot be a Gumroad address")
      expect(own.errors).to include("recipient_email cannot be the seller's address")
    end

    it "accepts a site contact sourced from a page on the reported site or on the Copyright Office directory" do
      on_site = call(pass_params.merge("recipient_source_url" => "https://legal.example.net/dmca"))
      expect(on_site).to be_success
    end

    it "rejects an address outside the site's domain when the contact page is on the reported site" do
      result = call(pass_params.merge("recipient_email" => "legal@attacker.example.org"))

      expect(result.errors).to eq(["recipient_email must be an address at example.net when the contact page is on the reported site; cite the Copyright Office directory for a third-party agent"])
      expect(report.reload.state).to eq("screening")
    end

    it "accepts a third-party agent's address when the contact comes from the Copyright Office directory" do
      result = call(pass_params.merge("recipient_email" => "agent@dmca-agents.example.org", "recipient_source_url" => "https://dmca.copyright.gov/osp/publicsearch.html"))

      expect(result).to be_success
    end

    it "accepts an address on a subdomain of the site's registrable domain" do
      expect(call(pass_params.merge("recipient_email" => "abuse@mail.example.net"))).to be_success
    end

    it "accepts a contact page on the apex domain when the reported file is on a subdomain" do
      cdn_report = create(:piracy_report, :screening, seller:, product:, url: "https://files.pirate.example/course.zip")

      result = described_class.new(report: cdn_report, actor: admin, params: pass_params.merge("recipient_source_url" => "https://pirate.example/dmca", "recipient_email" => "copyright@pirate.example").with_indifferent_access).call

      expect(result).to be_success
    end

    it "rejects a contact page on a different registrable domain or a different IP address" do
      cdn_report = create(:piracy_report, :screening, seller:, product:, url: "https://files.pirate.example/course.zip")
      ip_report = create(:piracy_report, :screening, seller:, product:, url: "http://10.9.1.1/course.zip")

      other = described_class.new(report: cdn_report, actor: admin, params: pass_params.merge("recipient_source_url" => "https://not-pirate.example/dmca").with_indifferent_access).call
      ip = described_class.new(report: ip_report, actor: admin, params: pass_params.merge("recipient_source_url" => "http://192.168.1.1/dmca").with_indifferent_access).call

      expect(other.errors).to eq(["recipient_source_url must be a page on pirate.example or dmca.copyright.gov"])
      expect(ip.errors).to eq(["recipient_source_url must be a page on 10.9.1.1 or dmca.copyright.gov"])
    end

    it "rejects a recipient sourced from a page on any other host" do
      site = call(pass_params.merge("recipient_source_url" => "https://attacker.example.org/dmca-contact"))
      host = call(pass_params.merge("recipient_kind" => "host", "recipient_source_url" => "https://example.net/copyright"))

      expect(site.errors).to eq(["recipient_source_url must be a page on example.net or dmca.copyright.gov"])
      expect(host.errors).to eq(["recipient_source_url must be a page on dmca.copyright.gov"])
    end

    it "rejects a recipient without a source URL" do
      expect(call(pass_params.merge("recipient_source_url" => "")).errors).to include("recipient_source_url must be an http(s) URL of at most 2048 characters")
    end
  end

  describe "a fail verdict" do
    it "declines the report with the agent's reasons and needs no recipient" do
      checks = { "page_offers_work" => { "passed" => false, "reason" => "The page sells a different course." } }

      result = call("verdict" => "fail", "checks" => checks)

      expect(result).to be_success
      report.reload
      expect(report.state).to eq("declined")
      expect(report.screening_checks["agent"]).to eq("page_offers_work" => { "passed" => false, "reason" => "The page sells a different course." })
      expect(report.events.order(:id).last.event).to eq("fail_screening")
    end

    it "still requires at least one check with a reason" do
      expect(call("verdict" => "fail", "checks" => {}).errors).to include("at least one check is required")
    end
  end

  it "rejects a verdict other than pass or fail" do
    expect(call(pass_params.merge("verdict" => "maybe")).errors).to include("verdict must be pass or fail")
  end

  it "refuses a report that is not being screened" do
    report.update!(state: "requested")

    expect(call(pass_params).errors).to eq(["The report is not being screened"])
  end
end
