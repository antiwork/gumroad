# frozen_string_literal: true

require "csv"

class Exports::AudienceExportService
  FIELDS = ["Subscriber Email", "Subscribed Time"].freeze
  SYNCHRONOUS_EXPORT_THRESHOLD = 5_000

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
      query.select(:id, :email, :min_created_at).find_each do |member|
        csv << [member.email, member.min_created_at]
      end
    end

    @tempfile.rewind

    self
  end

  def query
    query = @user.audience_members

    conditions = []
    conditions << "follower = true" if @options[:followers]
    conditions << "customer = true" if @options[:customers]
    conditions << "affiliate = true" if @options[:affiliates]

    query.where(conditions.join(" OR ")).order(:min_created_at)
  end

  def self.export(seller_id, recipient_id, audience_options = {})
    seller = User.find(seller_id)
    recipient = recipient_id ? User.find(recipient_id) : seller

    service = new(seller, audience_options)
    count = service.query.count

    if count > SYNCHRONOUS_EXPORT_THRESHOLD
      export = AudienceExport.create!(user: seller, recipient: recipient, audience_options: audience_options)
      Exports::Audience::CreateAndEnqueueChunksWorker.perform_async(export.id)
      nil
    else
      service.perform
    end
  end

  private
    def validate_options!
      unless @options[:followers] || @options[:customers] || @options[:affiliates]
        raise ArgumentError, "At least one audience type (followers, customers, or affiliates) must be selected"
      end
    end
end
