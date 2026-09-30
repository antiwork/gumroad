# frozen_string_literal: true

# The agent supplies only a verdict and its checks. The recipient comes from RecipientRegistry.
class PiracyReports::ScreenService
  Result = Struct.new(:report, :errors, keyword_init: true) do
    def success?
      errors.empty?
    end
  end

  # Anything but a boolean or its string form, such as [false], must not be read as true.
  PASSED_VALUES = { true => true, "true" => true, false => false, "false" => false }.freeze

  def initialize(report:, params:)
    @report = report
    @params = params
  end

  # The lock reloads the report, so a concurrent second request sees the first one's result.
  def call
    report.with_lock { screen }
  end

  private
    attr_reader :report, :params

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

    def input_errors
      errors = []
      errors << "verdict must be pass or fail" unless %w[pass fail].include?(verdict)
      errors.concat(check_errors)
      errors.concat(pass_errors) if verdict == "pass"
      errors << "a fail verdict needs at least one failed check" if verdict == "fail" && checks_from_agent.values.none? { _1["passed"] == false }
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
      errors
    end

    def pass
      rails_errors = PiracyReports::Eligibility.new(seller: report.seller, product: report.product).errors
      rails_errors << PiracyReport::HOSTED_ON_GUMROAD_ERROR if PiracyReport.gumroad_hosted?(report.url_host)
      return fail_report(checks_from_agent, rails_errors:) if rails_errors.any?

      recipient = PiracyReports::RecipientRegistry.for_host(report.url_host)
      return Result.new(report:, errors: [no_recipient_error]) if recipient.nil?

      report.assign_attributes(
        screening_verdict: "pass",
        screening_checks: { "agent" => checks_from_agent },
        screened_at: Time.current,
        recipient_name: recipient.name,
        recipient_email: recipient.email
      )
      report.notice_text = PiracyReports::NoticeRenderer.new(report).call
      report.notice_digest = Digest::SHA256.hexdigest(report.notice_text)
      report.pass_screening!
      Result.new(report:, errors: [])
    end

    def no_recipient_error
      "No verified recipient for #{report.url_host}. The report stays in screening until one is added to config/piracy_recipients.yml."
    end

    def fail_report(agent_checks, rails_errors: [])
      report.assign_attributes(
        screening_verdict: "fail",
        screening_checks: { "agent" => agent_checks, "rails" => rails_errors },
        screened_at: Time.current
      )
      report.fail_screening!
      Result.new(report:, errors: [])
    end
end
