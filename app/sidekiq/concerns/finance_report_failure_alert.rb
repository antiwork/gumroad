# frozen_string_literal: true

# Retry-exhaustion alerting for the finance/accounting report jobs.
#
# These jobs used to run with retry: 1 and no exhaustion hook, so a transient failure
# (a deploy at the wrong moment, a DB timeout on a month-boundary scan) silently dropped
# the report — finance noticed days later that the email never arrived, or didn't notice
# at all.
#
# Including this module registers a sidekiq_retries_exhausted block that emails the
# payments notification address with the failure context and the exact idempotent re-run
# command. All of these reports are read-only aggregations, so re-running one is always
# safe.
#
# If the including job's scheduled run fires with no args but its #perform computes
# time-dependent defaults (e.g. "last month"), define `.default_alert_args` returning
# those resolved defaults. The alert's re-run command is then pinned to the period the
# failed run was for, instead of re-resolving "last month" later — after the calendar has
# moved on — and silently computing the wrong period.
module FinanceReportFailureAlert
  def self.included(base)
    base.sidekiq_retries_exhausted do |job, exception|
      args = job["args"]
      args = base.default_alert_args if args.blank? && base.respond_to?(:default_alert_args)

      AccountingMailer.finance_report_job_failed(
        job["class"] || base.name, args, exception.class.name, exception.message
      ).deliver_later
    end
  end
end
