# frozen_string_literal: true

class SuspendUsersWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(author_id, user_ids, reason, additional_notes)
    User.where(id: user_ids).find_each(batch_size: 100) do |user|
      user.flag_for_tos_violation(author_id:, bulk: true)
      author_name = User.find(author_id).name_or_username
      content = "Suspended for a policy violation by #{author_name} on #{Time.current.to_fs(:formatted_date_full_month)} as part of mass suspension. Reason: #{reason}."
      content += "\nAdditional notes: #{additional_notes}" if additional_notes.present?
      user.suspend_for_tos_violation(author_id:, content:)
    end
  end
end
