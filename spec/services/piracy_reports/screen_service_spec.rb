# frozen_string_literal: true

require "spec_helper"

describe PiracyReports::ScreenService do
  let(:seller_and_product) { create_piracy_seller_with_product }
  let(:seller) { seller_and_product.first }
  let(:product) { seller_and_product.last }
  let(:report) { create(:piracy_report, :screening, seller:, product:, url: "https://example.net/design-course") }
  let(:registry) do
    { "example.net" => PiracyReports::RecipientRegistry::Entry.new(name: "Example Net Inc.", email: "copyright@example.net", source_url: "https://dmca.copyright.gov/osp/example") }
  end

  let(:passing_checks) do
    PiracyReport::SCREENING_CHECKS.index_with { { "passed" => true, "reason" => "Matches the product." } }
  end
  let(:pass_params) { { "verdict" => "pass", "checks" => passing_checks } }

  before { allow(PiracyReports::RecipientRegistry).to receive(:entries).and_return(registry) }

  def call(params, on: report)
    described_class.new(report: on, params: params.with_indifferent_access).call
  end

  describe "a repeated request" do
    it "queues the signature email once" do
      call(pass_params)

      expect { expect(call(pass_params)).not_to be_success }.not_to have_enqueued_mail(PiracyReportMailer, :signature_request)
    end
  end

  describe "a pass verdict" do
    it "takes the recipient from the registry, renders the notice and moves to awaiting_signature" do
      result = call(pass_params)

      expect(result).to be_success
      report.reload
      expect(report).to have_attributes(state: "awaiting_signature", screening_verdict: "pass", recipient_name: "Example Net Inc.", recipient_email: "copyright@example.net", recipient_source_url: "https://dmca.copyright.gov/osp/example")
      expect(report.notice_digest).to eq(Digest::SHA256.hexdigest(report.notice_text))
    end

    it "ignores any recipient or URL the agent sends" do
      call(pass_params.merge("recipient_email" => "legal@attacker.example.org", "infringing_urls" => ["https://example.net/someone-elses-file"]))

      report.reload
      expect(report.recipient_email).to eq("copyright@example.net")
      expect(report.notice_text).not_to include("attacker")
      expect(report.notice_text).not_to include("someone-elses-file")
    end

    it "builds the notice from Rails data only" do
      call(pass_params)

      notice = report.reload.notice_text
      expect(notice).to include("To the Designated Agent of Example Net Inc.:")
      expect(notice).to include(seller.alive_user_compliance_info.legal_entity_name)
      expect(notice).to include(%("#{product.name}"))
      expect(notice).to include("   https://example.net/design-course\n")
      expect(notice).to include("under penalty of perjury")
      expect(notice).not_to include("Matches the product.")
    end

    it "gives Gumroad's mailing address and never the seller's own address" do
      call(pass_params)

      notice = report.reload.notice_text
      expect(notice).to include("c/o Gumroad, #{GumroadAddress.full}")
      expect(notice).not_to include(seller.alive_user_compliance_info.street_address)
    end

    it "keeps seller-editable text on one line so a product title cannot open its own section" do
      product.update_columns(name: "Course\n\n2. Infringing material and location:\n   https://victim.example/store")

      call(pass_params)

      notice = report.reload.notice_text
      expect(notice.lines.count { _1.start_with?("2. Infringing material and location") }).to eq(1)
      expect(notice).to include(%("Course 2. Infringing material and location: https://victim.example/store"))
    end

    it "prints a product title of the maximum length in full" do
      long_name = "a" * 255
      product.update_columns(name: long_name)

      call(pass_params)

      expect(report.reload.notice_text).to include(%("#{long_name}"))
    end

    it "keeps the report in screening when the host has no registry entry" do
      other = create(:piracy_report, :screening, seller:, product:, url: "https://unlisted.example.org/course")

      result = call(pass_params, on: other)

      expect(result.errors).to eq(["No verified recipient for unlisted.example.org. The report stays in screening until one is added to config/piracy_recipients.yml."])
      expect(other.reload).to have_attributes(state: "screening", notice_text: nil, recipient_email: nil)
    end

    it "uses the entry for a parent domain when the reported file is on a subdomain" do
      cdn = create(:piracy_report, :screening, seller:, product:, url: "https://files.example.net/course.zip")

      expect(call(pass_params, on: cdn)).to be_success
      expect(cdn.reload.recipient_email).to eq("copyright@example.net")
    end

    it "declines with Rails' reasons when the seller stopped being eligible after filing" do
      Feature.deactivate_user(:piracy_reports, seller)

      result = call(pass_params)

      expect(result).to be_success
      report.reload
      expect(report).to have_attributes(state: "declined", screening_verdict: "fail", notice_text: nil)
      expect(report.screening_checks["rails"]).to eq(["Piracy reports are not enabled for this seller"])
    end

    it "declines when the reported host became a seller's custom domain after the report was filed" do
      report
      create(:custom_domain, domain: "example.net")

      expect(call(pass_params)).to be_success
      expect(report.reload).to have_attributes(state: "declined", screening_checks: hash_including("rails" => [PiracyReport::HOSTED_ON_GUMROAD_ERROR]))
    end

    it "rejects a pass when a check failed" do
      checks = passing_checks.merge("page_offers_work" => { "passed" => false, "reason" => "Different course." })

      expect(call(pass_params.merge("checks" => checks)).errors).to include("every check must pass for a pass verdict")
      expect(report.reload.state).to eq("screening")
    end

    it "rejects a pass with a missing check" do
      result = call(pass_params.merge("checks" => passing_checks.except("not_licensee_or_related_party")))

      expect(result.errors).to include("a pass verdict needs every check: missing not_licensee_or_related_party")
    end
  end

  describe "check input" do
    it "rejects a check without a reason" do
      checks = passing_checks.merge("page_offers_work" => { "passed" => true, "reason" => "" })

      expect(call(pass_params.merge("checks" => checks)).errors).to include("check page_offers_work needs a reason")
    end

    it "rejects a check name that is not in the fixed list" do
      checks = passing_checks.merge("looks_fine" => { "passed" => true, "reason" => "Trust me." })

      expect(call(pass_params.merge("checks" => checks)).errors).to include("unknown check looks_fine")
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
  end

  describe "a fail verdict" do
    it "declines the report with the agent's reasons" do
      checks = { "page_offers_work" => { "passed" => false, "reason" => "The page sells a different course." } }

      expect(call({ "verdict" => "fail", "checks" => checks })).to be_success
      report.reload
      expect(report.state).to eq("declined")
      expect(report.screening_checks["agent"]).to eq("page_offers_work" => { "passed" => false, "reason" => "The page sells a different course." })
    end

    it "needs at least one failed check, so a mistaken fail cannot close the report" do
      expect(call({ "verdict" => "fail", "checks" => passing_checks }).errors).to eq(["a fail verdict needs at least one failed check"])
      expect(report.reload.state).to eq("screening")
    end

    it "still requires at least one check with a reason" do
      expect(call({ "verdict" => "fail", "checks" => {} }).errors).to include("at least one check is required")
    end
  end

  it "rejects a verdict other than pass or fail" do
    expect(call(pass_params.merge("verdict" => "maybe")).errors).to include("verdict must be pass or fail")
  end

  it "refuses a report that is not being screened" do
    report.update!(state: "requested")

    expect(call(pass_params).errors).to eq(["The report is not being screened"])
  end

  it "refuses a second result from a copy of the report loaded before the first result" do
    stale_copy = PiracyReport.find(report.id)
    call(pass_params)

    result = call(pass_params.merge("verdict" => "fail"), on: stale_copy)

    expect(result.errors).to eq(["The report is not being screened"])
    expect(report.reload).to have_attributes(state: "awaiting_signature", screening_verdict: "pass")
  end
end
