# frozen_string_literal: true

# Owner: gumclaw; audit duplicate-instance purchase callbacks before changing the recipient.
Rails.application.config.active_record.run_commit_callbacks_on_first_saved_instances_in_transaction = true
# Owner: ershad; verify SQL log consumers before switching to SQLCommenter.
Rails.application.config.active_record.query_log_tags_format = :legacy
# Owner: gumclaw; audit required associations without database foreign keys before skipping parent checks.
Rails.application.config.active_record.belongs_to_required_validates_foreign_key = true
# Owner: gumclaw; prove purchase inventory/email callback ordering before reversing it.
Rails.application.config.active_record.run_after_transaction_callbacks_in_order_defined = false
# Owner: gumclaw; compare seller HTML rendering before adopting the HTML5 sanitizer.
Rails.application.config.action_view.sanitizer_vendor = Rails::HTML4::Sanitizer
# Owner: gumclaw; audit Active Job callers before changing transaction enqueue timing.
Rails.application.config.active_job.enqueue_after_transaction_commit = :never
# Owner: gumclaw; verify thumbnail delivery before serving WebP variants without conversion.
Rails.application.config.active_storage.web_image_content_types = %w[image/png image/jpeg image/gif]
# Owner: gumclaw; reconcile existing future-dated migrations before enabling timestamp validation.
Rails.application.config.active_record.validate_migration_timestamps = false
# Owner: gumclaw; audit regex-heavy validators before imposing a global timeout.
Regexp.timeout = nil
