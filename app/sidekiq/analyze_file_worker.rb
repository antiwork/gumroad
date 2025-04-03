# frozen_string_literal: true

class AnalyzeFileWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  def perform(id, analyzable_klass_name = ProductFile.name)
    return if Rails.env.test?

    analyzable_klass_name.constantize.find(id).analyze
  rescue Aws::S3::Errors::NotFound => e
    Rails.logger.info("AnalyzeFileWorker failed: Could not analyze #{analyzable_klass_name} #{id} (#{e.class}: #{e.message})")
  end
end
