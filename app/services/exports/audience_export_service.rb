# frozen_string_literal: true

require "csv"

class Exports::AudienceExportService
  FIELDS = ["Subscriber Email", "Subscribed Time"].freeze
  BATCH_SIZE = 10_000
  SYNCHRONOUS_EXPORT_THRESHOLD = 10_000

  def initialize(user, options = {})
    @user = user
    @options = options.with_indifferent_access
    timestamp = Time.current.to_fs(:db).gsub(/ |:/, "-")
    @filename = "Subscribers-#{@user.username}_#{timestamp}.csv"

    validate_options!
  end

  attr_reader :filename, :tempfile

  # Main entry point for exports.
  # Returns self for sync exports, false for async exports.
  def self.export(seller:, recipient: seller, options: {})
    service = new(seller, options)
    count = service.audience_count

    if count <= SYNCHRONOUS_EXPORT_THRESHOLD
      service.perform
    else
      Exports::Audience::EnqueueChunksWorker.perform_async(
        seller.id,
        recipient.id,
        options.to_h
      )
      false
    end
  end

  def perform
    @tempfile = Tempfile.new(["Subscribers", ".csv"], encoding: "UTF-8")

    CSV.open(@tempfile, "wb", headers: FIELDS, write_headers: true) do |csv|
      audience_query.in_batches(of: BATCH_SIZE) do |batch|
        batch.pluck(:email, :min_created_at).each { |row| csv << row }
      end
    end

    @tempfile.rewind

    self
  end

  def audience_count
    audience_query.count
  end

  private
    def audience_query
      query = @user.audience_members.select(:id, :email, :min_created_at)

      conditions = build_conditions
      return query.none if conditions.empty?

      query.where(conditions.join(" OR ")).order(:min_created_at)
    end

    def build_conditions
      conditions = []
      conditions << "follower = true" if @options[:followers]
      conditions << "customer = true" if @options[:customers]
      conditions << "affiliate = true" if @options[:affiliates]
      conditions
    end

    def validate_options!
      unless @options[:followers] || @options[:customers] || @options[:affiliates]
        raise ArgumentError, "At least one audience type (followers, customers, or affiliates) must be selected"
      end
    end
end
