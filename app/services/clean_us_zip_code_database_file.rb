# frozen_string_literal: true

# This script manipulates the United States zip codes file to only include information we need (zip codes and states).
# It's only meant to be executed locally.
#
# Steps:
#
# 1. Ask Sahil to purchase an Enterprise license from https://www.unitedstateszipcodes.org/zip-code-database/ with email address paypal@gumroad.com
# 2. After Sahil purchases, go to https://www.unitedstateszipcodes.org/order-download/
# 3. Enter paypal@gumroad.com (or the email he used for the purchase)
# 4. Download the `Enterprise in CSV Format` file (should be named zip_code_database_enterprise.csv) and place it in the /config directory
# 5. In a development Rails console: CleanUsZipCodeDatabaseFile.process
# 6. Commit, Pull Request, push
class CleanUsZipCodeDatabaseFile
  def self.process
    raise "Only run in development" unless Rails.env.development?

    source_file_path = "#{Rails.root}/config/zip_code_database_enterprise.csv"
    destination_file_path = "#{Rails.root}/config/zip_code_database.csv"

    File.delete(destination_file_path) if File.exist?(destination_file_path)
    rows = CSV.parse(File.read(source_file_path)).map! { |row| [row[0], row[6]] }

    CsvSafe.open(destination_file_path, "w") do |csv|
      rows.each do |row|
        csv << row
      end
    end

    File.delete(source_file_path) if File.exist?(source_file_path); nil
  end
end
