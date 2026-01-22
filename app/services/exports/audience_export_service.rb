# frozen_string_literal: true




class Exports::AudienceExportService
  FIELDS = ["Subscriber Email", "Subscribed Time"].freeze
  CHUNK_THRESHOLD = 10_000

  def initialize(user, options = {})
    @user = user
    @options = options.with_indifferent_access
    timestamp = Time.current.to_fs(:db).gsub(/ |:/, "-")
    @filename = "Subscribers-#{@user.username}_#{timestamp}.csv"
    validate_options!
  end

  attr_reader :filename, :tempfile

  def perform
    count = build_count_query(@user, @options)
    if count <= CHUNK_THRESHOLD
      perform_sync_export
    else
      export = AudienceExport.create!(seller: @user, recipient: @user)
      export.options = @options
      export.filename = @filename
      export.save!
      Exports::CreateAndEnqueueChunksWorker.perform_async(export.id)
      nil
    end
  end

  private

  def perform_sync_export
    @tempfile = Tempfile.new(["Subscribers", ".csv"], encoding: "UTF-8")
    CsvSafe.open(@tempfile, "wb", headers: FIELDS, write_headers: true) do |csv|
      query = build_query(@user, @options)
      query.order(:min_created_at).find_each do |member|
        csv << [member.email, member.min_created_at]
      end
    end
    @tempfile.rewind
    self
  end

  def build_query(user, options)
    options = options.with_indifferent_access
    query = user.audience_members.select(:id, :email, :min_created_at)
    scopes = []
    scopes << query.where(follower: true) if options[:followers]
    scopes << query.where(customer: true) if options[:customers]
    scopes << query.where(affiliate: true) if options[:affiliates]
    return query.none if scopes.empty?
    scopes.reduce(&:or)
  end

  def build_count_query(user, options)
    options = options.with_indifferent_access
    query = user.audience_members
    scopes = []
    scopes << query.where(follower: true) if options[:followers]
    scopes << query.where(customer: true) if options[:customers]
    scopes << query.where(affiliate: true) if options[:affiliates]
    return 0 if scopes.empty?
    scopes.reduce(&:or).count
  end

  def validate_options!
    unless @options[:followers] || @options[:customers] || @options[:affiliates]
      raise ArgumentError, "At least one audience type (followers, customers, or affiliates) must be selected"
    end
  end
end
