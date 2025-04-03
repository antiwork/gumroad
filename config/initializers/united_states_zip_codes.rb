# frozen_string_literal: true

# Known zip codes that don't show up in the US Zip Codes database.
KNOWN_ZIP_CODES = { "85144" => "AZ" }

# The United States Zip Codes website recommends that we update this file annually. https://www.unitedstateszipcodes.org/zip-code-database/
# Changes to 5-digit zip codes are infrequent. Instead of taking on an API dependency, we use this source of truth.
# See `CleanUsZipCodeDatabaseFile` for information on how to update this file.
ZIP_CODE_TO_STATE = CSV.parse(File.read("#{Rails.root}/config/zip_code_database.csv")).drop(1).map! { |row| [row[0], row[1]] }.to_h.merge(KNOWN_ZIP_CODES)
