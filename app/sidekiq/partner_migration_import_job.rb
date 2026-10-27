# frozen_string_literal: true

# Imports a claimed partner migration's products as drafts for the claiming creator.
#
# `results` records each product by its index in the payload, in the same transaction that creates
# the product. A retry skips the products already recorded, so it does not create duplicates.
class PartnerMigrationImportJob
  include Sidekiq::Job
  sidekiq_options queue: :long, retry: 5, lock: :until_executed

  AVATAR_DOWNLOAD_DURATION = 1.minute

  # Errors that a retry cannot fix. The product is recorded as failed and the import continues.
  # Other errors, such as a network error or PartnerMigration::RemoteFileTransfer::TemporaryError,
  # reach Sidekiq, which retries the job.
  PRODUCT_ERRORS = [
    PartnerMigration::RemoteFileTransfer::Error, SsrfFilter::Error, URI::InvalidURIError,
    ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved, Link::LinkInvalid
  ].freeze

  sidekiq_retries_exhausted do |job, exception|
    ApplicationRecord.connected_to(role: :writing) do
      migration = PartnerMigration.find_by(id: job["args"].first)
      next unless migration

      migration.with_lock do
        if migration.status == PartnerMigration::STATUS_CLAIMED
          migration.update!(status: PartnerMigration::STATUS_FAILED, completed_at: Time.current, failure_reason: exception.message.truncate(PartnerMigration::MAX_FAILURE_REASON_LENGTH))
        end
      end
      PartnerMigrationNotificationJob.perform_async(migration.id) if migration.completed_at
    end
  end

  def perform(partner_migration_id)
    # The claim may not have replicated yet.
    ApplicationRecord.connected_to(role: :writing) do
      migration = PartnerMigration.find(partner_migration_id)
      # A manual retry enqueues inside its transaction, so wait for that transaction to commit.
      unless migration.with_lock { migration.status == PartnerMigration::STATUS_CLAIMED }
        # Retry a failed notification enqueue without importing the products again.
        PartnerMigrationNotificationJob.perform_async(migration.id) if migration.completed_at
        return
      end

      attach_profile_avatar(migration)

      # An error that a retry may fix does not hold back the products after it. The job imports them,
      # then raises the first such error, so the Sidekiq retry imports only the products left.
      retry_error = nil
      migration.products.each_with_index do |attributes, index|
        result = migration.results&.dig(index.to_s)
        if result.nil?
          import_product(migration, index, attributes)
        elsif result["media_pending"]
          # A previous attempt stopped after it created the product. Retrying the media could add
          # the same covers twice, so report it instead.
          record_result(migration, index, "product_id" => result["product_id"], "warnings" => ["The import stopped before the covers and thumbnail were added."])
        end
      rescue StandardError => e
        retry_error ||= e
        # A rolled-back transaction can leave a result in memory that was never saved.
        migration.reload
      end
      raise retry_error if retry_error

      status = migration.results.to_h.values.any? { _1["error"].present? } ? PartnerMigration::STATUS_FAILED : PartnerMigration::STATUS_COMPLETED
      migration.update!(status:, completed_at: Time.current)
      PartnerMigrationNotificationJob.perform_async(migration.id)
    end
  end

  private
    # Only an account that this import created takes the partner's avatar. A missing or invalid
    # picture is skipped: the seller can add one in their profile. Only runs before the first product
    # result try it, each briefly, so a slow picture cannot hold back the products or their retries.
    def attach_profile_avatar(migration)
      user = migration.user
      url = migration.profile.to_h["avatar_url"]
      return if url.blank? || !migration.account_created || user.avatar.attached? || migration.results.present?

      migration.touch
      PartnerMigration::RemoteFileTransfer.download(url, max_bytes: User::Validations::MAXIMUM_AVATAR_FILE_SIZE, max_duration: AVATAR_DOWNLOAD_DURATION) do |tempfile, filename|
        content_type = Marcel::MimeType.for(tempfile, name: filename)
        next unless user.valid_avatar_content_type?(content_type)

        blob = ActiveStorage::Blob.create_and_upload!(io: tempfile, filename:, content_type:)
        blob.purge unless user.avatar.attach(blob)
      rescue StandardError
        blob&.purge
        raise
      end
    # The avatar is optional, so no error from it may stop the products from importing.
    rescue StandardError => e
      Rails.logger.info("Partner migration #{migration.id}: avatar not imported (#{e.class})")
    end

    def import_product(migration, index, attributes)
      importer = PartnerMigration::ProductImporter.new(seller: migration.user, attributes:, heartbeat: -> { migration.touch })
      migration.touch
      file_urls = importer.download_files
      product = begin
        ActiveRecord::Base.transaction do
          importer.create_product!(file_urls).tap { record_result(migration, index, "product_id" => _1.external_id, "media_pending" => true) }
        end
      rescue StandardError
        # An after_commit callback can raise after the product is saved. Its files must stay.
        importer.discard_uploaded_files unless product_recorded?(migration, index)
        raise
      end

      warnings = importer.attach_media(product)
      record_result(migration, index, { "product_id" => product.external_id, "warnings" => warnings.presence }.compact)
    rescue SsrfFilter::UnresolvedHostname
      # A DNS lookup can fail for a moment, so Sidekiq retries it.
      raise
    rescue *PRODUCT_ERRORS => e
      # A saved product keeps its result. The retry reports its unfinished media.
      raise if product_recorded?(migration, index)

      record_result(migration, index, "error" => e.message)
    end

    def product_recorded?(migration, index)
      PartnerMigration.where(id: migration.id).pick(:results)&.key?(index.to_s)
    end

    def record_result(migration, index, result)
      migration.update!(results: (migration.results || {}).merge(index.to_s => result))
    end
end
