# frozen_string_literal: true

# Validates the agent's screening result and moves the report on. The agent supplies a verdict,
# its judgment checks and the recipient. It supplies no notice text and no URLs: Rails
# renders that from a template, so nothing read on a pirate page can reach the signed notice.
class PiracyReports::ScreenService
  Result = Struct.new(:report, :errors, keyword_init: true) do
    def success?
      errors.empty?
    end
  end

  # `passed` arrives as a JSON boolean or a form string. Anything else, such as [false], is
  # malformed input and must not be read as true.
  PASSED_VALUES = { true => true, "true" => true, false => false, "false" => false }.freeze
  MAX_NAME_LENGTH = 100
  NAME_FORMAT = /\A[\p{L}\p{N} .,&'-]+\z/

  def initialize(report:, actor:, params:)
    @report = report
    @actor = actor
    @params = params
  end

  # The lock reloads the report, so a second request that arrives while the first is running
  # sees the state the first one left and is refused.
  def call
    report.with_lock { screen }
  end

  private
    attr_reader :report, :actor, :params

    def screen
      return Result.new(report:, errors: ["The report is not being screened"]) unless report.screening?

      errors = input_errors
      return Result.new(report:, errors:) if errors.any?

      verdict == "pass" ? pass : fail_report(checks_from_agent)
    end

    def verdict
      params[:verdict].to_s
    end

    def checks_from_agent
      @checks_from_agent ||= well_formed_checks.transform_values do |entry|
        { "passed" => PASSED_VALUES[entry[:passed]], "reason" => entry[:reason].to_s.strip }
      end
    end

    def check_params
      @check_params ||= (params[:checks].is_a?(Hash) ? params[:checks] : {}).with_indifferent_access
    end

    def well_formed_checks
      check_params.slice(*PiracyReport::SCREENING_CHECKS).select { |_, entry| entry.is_a?(Hash) }
    end

    def recipient
      @recipient ||= {
        kind: params[:recipient_kind].to_s,
        name: params[:recipient_name].to_s.squish,
        email: params[:recipient_email].to_s.strip,
        source_url: params[:recipient_source_url].to_s.strip
      }
    end

    def input_errors
      errors = []
      errors << "verdict must be pass or fail" unless %w[pass fail].include?(verdict)
      errors.concat(check_errors)
      errors.concat(pass_errors) if verdict == "pass"
      errors
    end

    def check_errors
      errors = (check_params.keys - PiracyReport::SCREENING_CHECKS).map { "unknown check #{_1}" }
      errors.concat((check_params.slice(*PiracyReport::SCREENING_CHECKS).keys - well_formed_checks.keys).map { "check #{_1} must be an object" })
      errors << "at least one check is required" if check_params.empty?
      checks_from_agent.each do |key, entry|
        errors << "check #{key} passed must be true or false" if entry["passed"].nil?
        errors << "check #{key} needs a reason" if entry["reason"].blank?
        errors << "check #{key} reason is too long" if entry["reason"].length > PiracyReport::MAX_REASON_LENGTH
      end
      errors
    end

    def pass_errors
      errors = []
      missing = PiracyReport::SCREENING_CHECKS - checks_from_agent.keys
      errors << "a pass verdict needs every check: missing #{missing.join(", ")}" if missing.any?
      errors << "every check must pass for a pass verdict" unless checks_from_agent.values.all? { _1["passed"] }
      errors.concat(recipient_errors)
      errors
    end

    def recipient_errors
      errors = []
      errors << "recipient_kind must be one of #{PiracyReport::RECIPIENT_KINDS.join(", ")}" unless PiracyReport::RECIPIENT_KINDS.include?(recipient[:kind])
      unless recipient[:name].length.between?(1, MAX_NAME_LENGTH) && recipient[:name].match?(NAME_FORMAT)
        errors << "recipient_name must be 1 to #{MAX_NAME_LENGTH} letters, digits, spaces or . , & ' -"
      end
      errors << "recipient_email is invalid" unless recipient[:email].length <= 254 && EmailFormatValidator.valid?(recipient[:email])
      errors << "recipient_email cannot be a Gumroad address" if gumroad_email?(recipient[:email])
      errors << "recipient_email cannot be the seller's address" if seller_email?(recipient[:email])
      errors.concat(source_url_errors)
      errors
    end

    # Rails cannot read the page the agent cites, so it limits where the citation may point and what
    # it may name. A contact cited from the reported site's own domain must be an address on that
    # domain, so a fake "DMCA contact" page on a shared platform cannot name a stranger's address.
    # A third-party agent must come from the Copyright Office directory. A hosting provider has no
    # page on the reported site, so only the directory qualifies.
    def source_url_errors
      uri = PiracyReport.parse_http_url(recipient[:source_url])
      if uri.nil? || recipient[:source_url].length > PiracyReport::MAX_URL_LENGTH
        return ["recipient_source_url must be an http(s) URL of at most #{PiracyReport::MAX_URL_LENGTH} characters"]
      end

      host = PiracyReport.normalized_host(uri.host)
      directory = PiracyReport::COPYRIGHT_DIRECTORY_HOST
      return [] if host == directory || host.end_with?(".#{directory}")

      site = PiracyReport.registrable_domain(report.url_host)
      if recipient[:kind] == "site" && PiracyReport.registrable_domain(host) == site
        return email_on_site?(site) ? [] : ["recipient_email must be an address at #{site} when the contact page is on the reported site; cite the Copyright Office directory for a third-party agent"]
      end

      ["recipient_source_url must be a page on #{[("#{site}" if recipient[:kind] == "site"), directory].compact.join(" or ")}"]
    end

    # A heuristic. A site that gives out mailboxes on its own domain (a free-mail provider that also
    # hosts files) can still pass. The control is slice 2: the seller sees the recipient and its
    # source before signing.
    def email_on_site?(site)
      # A malformed address already has its own error.
      return true unless EmailFormatValidator.valid?(recipient[:email])

      PiracyReport.registrable_domain(recipient[:email].to_s.split("@").last.to_s) == site
    end

    def gumroad_email?(email)
      PiracyReport.gumroad_host?(email.to_s.split("@").last.to_s)
    end

    def seller_email?(email)
      [report.seller.email, report.seller.unconfirmed_email].compact.any? { _1.casecmp?(email) }
    end

    def pass
      rails_errors = PiracyReports::Eligibility.new(seller: report.seller, product: report.product).errors
      rails_errors << PiracyReport::HOSTED_ON_GUMROAD_ERROR if PiracyReport.gumroad_hosted?(report.url_host)
      return fail_report(checks_from_agent, rails_errors:) if rails_errors.any?

      report.assign_attributes(
        screening_verdict: "pass",
        screening_checks: { "agent" => checks_from_agent },
        screened_at: Time.current,
        infringing_urls: [report.url],
        recipient_kind: recipient[:kind],
        recipient_name: recipient[:name],
        recipient_email: recipient[:email],
        recipient_source_url: recipient[:source_url]
      )
      report.notice_text = PiracyReports::NoticeRenderer.new(report).call
      report.notice_digest = Digest::SHA256.hexdigest(report.notice_text)
      report.signature_statement_version = PiracyReports::NoticeRenderer::STATEMENT_VERSION
      report.pass_screening!(actor)
      Result.new(report:, errors: [])
    end

    def fail_report(agent_checks, rails_errors: [])
      report.assign_attributes(
        screening_verdict: "fail",
        screening_checks: { "agent" => agent_checks, "rails" => rails_errors },
        screened_at: Time.current
      )
      report.fail_screening!(actor)
      Result.new(report:, errors: [])
    end
end
