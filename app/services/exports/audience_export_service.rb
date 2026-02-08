# frozen_string_literal: true

class Exports::AudienceExportService
  FIELDS = ["Subscriber Email", "Subscribed Time"].freeze

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

    CsvSafe.open(@tempfile, "wb", headers: FIELDS, write_headers: true) do |csv|
      conditions = []
      conditions << "follower = true" if @options[:followers]
      conditions << "customer = true" if @options[:customers]
      conditions << "affiliate = true" if @options[:affiliates]

      sql = @user.audience_members
        .select(:email, :min_created_at)
        .where(conditions.join(" OR "))
        .order(:id)
        .to_sql

      ActiveRecord::Base.connection.exec_query(sql).each do |row|
        csv << [row["email"], row["min_created_at"]]
      end
    end

    @tempfile.rewind

    self
  end

  private
    def validate_options!
      unless @options[:followers] || @options[:customers] || @options[:affiliates]
        raise ArgumentError, "At least one audience type (followers, customers, or affiliates) must be selected"
      end
    end
end
