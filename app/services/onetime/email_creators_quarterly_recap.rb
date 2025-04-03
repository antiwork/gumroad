# frozen_string_literal: true

class Onetime::EmailCreatorsQuarterlyRecap
  DEFAULT_REPLY_TO_EMAIL = "Sahil Lavingia <sahil@gumroad.com>"
  MIN_QUARTER_SIZE_IN_DAYS = 85.days

  private_constant :MIN_QUARTER_SIZE_IN_DAYS

  attr_reader :installment_external_id, :start_time, :end_time, :reply_to, :skip_user_ids, :emailed_user_ids

  def initialize(installment_external_id:, start_time:, end_time:, skip_user_ids: [], reply_to: DEFAULT_REPLY_TO_EMAIL)
    @installment_external_id = installment_external_id
    @start_time = start_time.to_date
    @end_time = end_time.to_date
    @skip_user_ids = skip_user_ids
    @reply_to = reply_to
    @emailed_user_ids = []
  end

  def process
    installment = Installment.find_by_external_id(installment_external_id)
    raise "Installment not found" unless installment.present?
    raise "Installment must not allow comments" if installment.allow_comments?
    raise "Installment must not be published or scheduled to publish" if installment.published? || installment.ready_to_publish?
    raise "Date range must be at least 85 days" if (end_time - start_time).days < MIN_QUARTER_SIZE_IN_DAYS

    WithMaxExecutionTime.timeout_queries(seconds: 10.minutes) do
      Purchase.where(created_at: start_time..end_time).successful.select(:seller_id).distinct.pluck(:seller_id).each_slice(1000) do |user_ids_slice|
        User.where(id: user_ids_slice).not_suspended.alive.find_each do |seller|
          next if seller.id.in?(skip_user_ids)
          next if seller.form_email.blank?
          OneOffMailer.email_using_installment(email: seller.form_email, installment_external_id:, reply_to:).deliver_later(queue: "low")
          @emailed_user_ids << seller.id
        end
      end
    end

    emailed_user_ids
  end
end
