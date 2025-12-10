# frozen_string_literal: true

require "csv"

class Exports::AudienceExportService
  FIELDS = ["Subscriber Email", "Subscribed Time"].freeze
  BATCH_SIZE = 5_000

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
      build_query.find_each(batch_size: BATCH_SIZE) do |member|
        csv << [member.email, member.min_created_at]
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

    def build_query
      conditions = []
      conditions << "follower = TRUE" if @options[:followers]
      conditions << "customer = TRUE" if @options[:customers]
      conditions << "affiliate = TRUE" if @options[:affiliates]

      @user.audience_members
        .select(:id, :email, :min_created_at)
        .where(conditions.join(" OR "))
    end
end
