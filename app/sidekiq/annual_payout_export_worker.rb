# frozen_string_literal: true

class AnnualPayoutExportWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low

  def perform(user_id, year, send_email = false)
    user = User.find user_id
    payout_data = nil

    WithMaxExecutionTime.timeout_queries(seconds: 1.hour) do
      payout_data = Exports::Payouts::Annual.new(user:,
                                                 year:).perform
    end

    if payout_data && payout_data[:csv_file] && payout_data[:total_amount] > 0
      csv_file = payout_data[:csv_file]

      if user.financial_annual_report_url_for(year:).nil?
        user.annual_reports.attach(
          io: csv_file,
          filename: "Financial summary for #{year}.csv",
          content_type: "text/csv",
          metadata: { year: }
        )
      end

      if send_email
        ContactingCreatorMailer.annual_payout_summary(user_id, year, payout_data[:total_amount]).deliver_now
      end
    end
  ensure
    if defined?(csv_file) && csv_file.respond_to?(:unlink)
      # https://ruby-doc.org/stdlib-2.7.0/libdoc/tempfile/rdoc/Tempfile.html#class-Tempfile-label-Explicit+close
      csv_file.close
      csv_file.unlink
    end
  end
end
