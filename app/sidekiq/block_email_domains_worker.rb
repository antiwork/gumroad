# frozen_string_literal: true

class BlockEmailDomainsWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(author_id, email_domains)
    now = Time.current
    email_domains.each do |email_domain|
      record = PlatformBlock.create_or_find_by!(object_type: BLOCKED_OBJECT_TYPES[:email_domain], object_value: email_domain)
      record.update!(blocked_at: now, blocked_by: author_id, expires_at: nil)
    end
  end
end
