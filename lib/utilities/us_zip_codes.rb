# frozen_string_literal: true

module UsZipCodes
  # Given a zip code in the United States, identifies the state code.
  # 5-digit zip codes are supported.
  # Zip+4 is also supported, but only the first 5 digits are used to determine the state.
  # Accepts surrounding whitespace. Accepts a single whitespace or hyphen in between zip+4.
  def self.identify_state_code(zip_code)
    return if zip_code.blank?
    zip_string = zip_code.to_s.strip

    # Support a 5-digit zip, or zip+4.
    valid_structure = (zip_string.length == 5 && zip_string !~ /\D/) ||
                      (zip_string.length == 9 && zip_string !~ /\D/) ||
                      (zip_string.length == 10 && !!(separator = [" ", "-"].find { |char| char == zip_string[5] }) && zip_string.split(separator).all? { |part| part !~ /\D/  })

    return unless valid_structure

    ZIP_CODE_TO_STATE[zip_string[0, 5]]
  end
end
