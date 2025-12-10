# frozen_string_literal: true

require "csv"

class Exports::AudienceExportService
  FIELDS = ["Subscriber Email", "Subscribed Time"].freeze
  # Threshold for switching to chunked processing
  # Exports with more members than this will be processed asynchronously in chunks
  SYNCHRONOUS_EXPORT_THRESHOLD = 2_000

  def initialize(user, options = {})
    @user = user
    @options = options.with_indifferent_access
    timestamp = Time.current.to_fs(:db).gsub(/ |:/, "-")
    @filename = "Subscribers-#{@user.username}_#{timestamp}.csv"

    validate_options!
  end

  attr_reader :filename, :tempfile

  def perform
    @tempfile = Tempfile.new(["Subscribers", ".csv"], encoding: "UTF-8")

    CSV.open(@tempfile, "wb", headers: FIELDS, write_headers: true) do |csv|
      query = @user.audience_members.select(:id, :email, :min_created_at)

      conditions = []
      conditions << "follower = true" if @options[:followers]
      conditions << "customer = true" if @options[:customers]
      conditions << "affiliate = true" if @options[:affiliates]

      query = query.where(conditions.join(" OR "))

      query.order(:min_created_at).find_each do |member|
        csv << [member.email, member.min_created_at]
      end
    end

    @tempfile.rewind

    self
  end

  def self.export(user:, recipient:, audience_options: {})
    query = user.audience_members

    conditions = []
    conditions << "follower = true" if audience_options[:followers]
    conditions << "customer = true" if audience_options[:customers]
    conditions << "affiliate = true" if audience_options[:affiliates]

    query = query.where(conditions.join(" OR ")) if conditions.any?
    count = query.count

    if count <= SYNCHRONOUS_EXPORT_THRESHOLD
      new(user, audience_options).perform
    else
      export = AudienceExport.create!(
        recipient: recipient,
        audience_options: audience_options
      )
      Exports::Audience::CreateAndEnqueueChunksWorker.perform_async(export.id)
      false
    end
  end

  private
    def validate_options!
      unless @options[:followers] || @options[:customers] || @options[:affiliates]
        raise ArgumentError, "At least one audience type (followers, customers, or affiliates) must be selected"
      end
    end
end
