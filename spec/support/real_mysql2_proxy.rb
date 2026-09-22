# frozen_string_literal: true

RSpec.shared_context "real mysql2 proxy pools" do
  self.use_transactional_tests = false

  before(:context) do
    @original_database = ActiveRecord::Base.connection_db_config.configuration_hash
    @original_replica_flag = ENV["USE_DB_WORKER_REPLICAS"]
    @original_connection_class = ApplicationRecord.connection_class?
    @schema_client = Mysql2::Client.new(**@original_database.slice(:host, :port, :username, :password))
    @routing_databases = %w[primary replica].map { |role| "#{@original_database.fetch(:database)}_routing_#{Process.pid}_#{role}" }
    tables = @schema_client.query("SHOW TABLES FROM `#{@original_database.fetch(:database)}`").map { _1.values.first }
    @routing_databases.each do |database|
      @schema_client.query("CREATE DATABASE `#{database}`")
      tables.each { |table| @schema_client.query("CREATE TABLE `#{database}`.`#{table}` LIKE `#{@original_database.fetch(:database)}`.`#{table}`") }
    end
    ENV["USE_DB_WORKER_REPLICAS"] = "true"
    @primary_config = @original_database.merge(adapter: "mysql2_proxy", database: @routing_databases.first)
    @replica_config = @original_database.merge(adapter: "mysql2", database: @routing_databases.last, replica: true)
    ApplicationRecord.connects_to database: { writing: @primary_config, reading: @replica_config }
    @primary = ApplicationRecord.connection
    @replica = ApplicationRecord.connected_to(role: :reading) { ApplicationRecord.connection }
    @primary.raw_connection.query("SET @routing_pool = 'primary'")
    @replica.raw_connection.query("SET @routing_pool = 'replica'")
  end

  after(:context) do
    ActiveRecord::Base.connection_handler.remove_connection_pool("ActiveRecord::Base", role: :reading)
    ActiveRecord::Base.establish_connection(@original_database)
    ApplicationRecord.connection_class = @original_connection_class
    ENV["USE_DB_WORKER_REPLICAS"] = @original_replica_flag
    @routing_databases&.each { @schema_client.query("DROP DATABASE IF EXISTS `#{_1}`") }
    @schema_client&.close
  end

  around do |example|
    previous = ActiveRecordProxyAdapters::Contextualizer.current_context
    cold_write_context
    example.run
  ensure
    ActiveRecordProxyAdapters::Contextualizer.current_context = previous
  end

  def cold_write_context
    ActiveRecordProxyAdapters::Contextualizer.current_context = ActiveRecordProxyAdapters::Context.new({})
  end

  def primary_setup(&block)
    ActiveRecord::Base.connected_to(role: :writing, &block)
  ensure
    cold_write_context
  end

  def serving_pool(connection = ApplicationRecord.connection)
    connection.select_value("SELECT @routing_pool")
  end

  def replicate_record(record)
    table = record.class.table_name
    @schema_client.query("INSERT INTO `#{@routing_databases.last}`.`#{table}` SELECT * FROM `#{@routing_databases.first}`.`#{table}` WHERE id = #{Integer(record.id)}")
  end

  def record_serving_reads(&block)
    reads = []
    subscriber = lambda do |*, payload|
      next unless payload[:sql].match?(/\ASELECT\b/i)
      reads << [payload[:sql], payload[:connection].raw_connection.query("SELECT @routing_pool", as: :array).first.first]
    end
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record", &block)
    reads
  end
end
