# frozen_string_literal: true

class UserComplianceInfoRequest < ApplicationRecord
  include ExternalId
  include JsonData
  include FlagShihTzu

  belongs_to :user, optional: true
  validates :user, presence: true

  has_flags 1 => :only_needs_field_to_be_partially_provided,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  attr_json_data_accessor :stripe_event_id
  attr_json_data_writer :emails_sent_at
  attr_json_data_accessor :sg_verification_reminder_sent_at
  attr_json_data_accessor :verification_error

  state_machine :state, initial: :requested do
    before_transition any => :provided, :do => lambda { |user_compliance_info_request|
      user_compliance_info_request.provided_at = Time.current
    }

    event :mark_provided do
      transition requested: :provided
    end
  end

  scope :requested, -> { where(state: :requested) }
  scope :provided, -> { where(state: :provided) }
  scope :only_needs_field_to_be_partially_provided, lambda { |does_only_needs_field_to_be_partially_provided = true|
    where(
      "flags & ? = ?",
      flag_mapping["flags"][:only_needs_field_to_be_partially_provided],
      does_only_needs_field_to_be_partially_provided ? flag_mapping["flags"][:only_needs_field_to_be_partially_provided] : 0
    )
  }

  def emails_sent_at
    email_sent_at_raw = json_data_for_attr("emails_sent_at", default: [])
    email_sent_at_raw.map { |email_sent_at| email_sent_at.is_a?(String) ? Time.zone.parse(email_sent_at) : email_sent_at }
  end

  def last_email_sent_at
    emails_sent_at.last
  end

  def record_email_sent!(email_sent_at = Time.current)
    self.emails_sent_at = emails_sent_at << email_sent_at
    save!
  end

  def self.handle_new_user_compliance_info(user_compliance_info)
    UserComplianceInfoFields.all_fields_on_user_compliance_info.each do |field|
      field_value = user_compliance_info.send(field)
      field_value = field_value.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")) if field_value.is_a?(Strongbox::Lock)
      next if field_value.blank?

      field_filter = UserComplianceInfoFieldProperty.property_for_field(
        field,
        UserComplianceInfoFieldProperty::FILTER,
        country: user_compliance_info.country_code
      )
      field_value = field_value.scan(field_filter).join if field_filter
      next if field_value.blank?

      field_expected_length = UserComplianceInfoFieldProperty.property_for_field(
        field,
        UserComplianceInfoFieldProperty::LENGTH,
        country: user_compliance_info.country_code
      )

      field_provided_in_part = field_value.length < field_expected_length if field_expected_length.present?

      requests = user_compliance_info.user.user_compliance_info_requests.requested.where(field_needed: field)
      requests = requests.only_needs_field_to_be_partially_provided if field_provided_in_part
      requests.find_each(&:mark_provided!)
    end
  end

  def self.handle_new_bank_account(bank_account)
    bank_account.user.user_compliance_info_requests.requested.where(field_needed: UserComplianceInfoFields::BANK_ACCOUNT).find_each(&:mark_provided!)
  end

  def verification_error_message
    return nil if verification_error.blank?
    return verification_error["message"] if verification_error["message"]

    case verification_error["code"]
    when "verification_directors_mismatch"
      "The provided directors on the account could not be verified. Correct any errors on the provided directors or upload a document that matches the provided information."
    when "verification_document_address_mismatch"
      "The address on the ID document doesn’t match the address provided on the account. Please verify and correct the provided address on the account, or upload a document with address that matches the account."
    when "verification_document_address_missing"
      "The uploaded document is missing the address information. Please upload another document that contains the address information."
    when "verification_document_corrupt"
      "The document verification failed as the file was corrupt. Please provide a clearly legible color document (8,000 pixels by 8,000 pixels or smaller), 10 MB or less in size, in JPG or PNG format. Please make sure the file contains all required pages of the document and is not password protected."
    when "verification_document_country_not_supported"
      "The provided document is not an acceptable form of ID from a supported country, or is not a type of legal entity document that is expected. Please provide a new file that meets that requirement."
    when "verification_document_directors_mismatch"
      "The directors on the document did not match the directors on the account. Upload a document with matching directors or update the directors on the account."
    when "verification_document_dob_mismatch"
      "The date of birth on the ID document doesn’t match the date of birth provided on the account. Please verify and correct the provided date of birth on the account, or upload a document with date of birth that matches the account."
    when "verification_document_duplicate_type"
      "The same type of document was used twice. Two unique types of documents are required for verification. Upload two different documents."
    when "verification_document_expired"
      "The issue or expiry date is missing on the document, or the document is expired. If it’s an identity document, its expiration date must be after the date the document was submitted. If it’s an address document, the issue date must be within the last six months."
    when "verification_document_failed_copy"
      "Copies (including photos or scans) of the original document cannot be read. Please upload the original document in color (8,000 pixels by 8,000 pixels or smaller), 10 MB or less in size, in JPG or PNG format. Please make sure the file contains all required pages of the document and is not password protected."
    when "verification_document_failed_greyscale"
      "The document verification failed as the file was in gray scale. Please provide a clearly legible color image (8,000 pixels by 8,000 pixels or smaller), 10 MB or less in size, in JPG or PNG format. Please make sure the file contains all required pages of the document and is not password protected."
    when "verification_document_failed_other"
      "There was a problem with verification of the document that you provided."
    when "verification_document_fraudulent"
      "The document might have been altered so it could not be verified."
    when "verification_document_id_number_mismatch"
      "The ID number on the ID document doesn’t match the ID number provided on the account. Please verify and correct the provided ID number on the account, or upload a document with ID number that matches the account."
    when "verification_document_id_number_missing"
      "The uploaded document is missing the ID number. Please upload another document that contains the ID number."
    when "verification_document_incomplete"
      "The document verification failed as it was incomplete. Please provide a clearly legible color image (8,000 pixels by 8,000 pixels or smaller), which is 10 MB or less in size, in JPG or PNG format. Please make sure the file contains all required pages of the document and is not password protected."
    when "verification_document_invalid"
      "The provided document is not an acceptable form of ID from a supported country, or is not a type of legal entity document that is expected. Please provide a new file that meets that requirement."
    when "verification_document_issue_or_expiry_date_missing"
      "The issue or expiry date is missing on the document, or the document is expired. If it’s an identity document, its expiration date must be after the date the document was submitted. If it’s an address document, the issue date must be within the last six months."
    when "verification_document_manipulated"
      "The document might have been altered so it could not be verified."
    when "verification_document_missing_back"
      "The document verification failed as the back side of the document was not provided. Please provide a clearly legible color image (8,000 pixels by 8,000 pixels or smaller), which is 10 MB or less in size, in JPG or PNG format. Please make sure the file contains all required pages of the document and is not password protected."
    when "verification_document_missing_front"
      "The document upload failed as the front side of the document was not provided. Please provide a clearly legible color image (8,000 pixels by 8,000 pixels or smaller), which is 10 MB or less in size, in JPG or PNG format. Please make sure the file contains all required pages of the document and is not password protected."
    when "verification_document_name_mismatch"
      "The name on the ID document doesn’t match the name provided on the account. Please verify and correct the provided name on the account, or upload a document with name that matches the account."
    when "verification_document_name_missing"
      "The uploaded document is missing the name. Please upload another document that contains the name."
    when "verification_document_not_readable"
      "The document verification failed as it was not readable. Please provide a valid color image (8,000 pixels by 8,000 pixels or smaller), which is 10 MB or less in size, in JPG or PNG format. Please make sure the file contains all required pages of the document and is not password protected."
    when "verification_document_not_signed"
      "The document verification failed as it was not signed. Please provide a clearly legible color image (8,000 pixels by 8,000 pixels or smaller), which is 10 MB or less in size, in JPG or PNG format. Please make sure the file contains all required pages of the document and is not password protected."
    when "verification_document_not_uploaded"
      "The document verification failed due to a problem with the file itself. Please provide a clearly legible color image (8,000 pixels by 8,000 pixels or smaller), which is 10 MB or less in size, in JPG or PNG format. Please make sure the file contains all required pages of the document and is not password protected."
    when "verification_document_photo_mismatch"
      "The photo on the ID document doesn’t match the photo provided on the account. Please verify and correct the provided photo on the account, or upload a document with photo that matches the account."
    when "verification_document_too_large"
      "The document verification failed as the file was too large. Please provide a clearly legible color image (8,000 pixels by 8,000 pixels or smaller), which is 10 MB or less in size, in JPG or PNG format. Please make sure the file contains all required pages of the document and is not password protected."
    when "verification_document_type_not_supported"
      "The provided document is not an acceptable form of ID from a supported country, or is not a type of legal entity document that is expected. Please provide a new file that meets that requirement."
    when "verification_extraneous_directors"
      "We have identified extra directors that we haven’t been able to verify. Please remove any extraneous directors from the account."
    when "verification_failed_address_match"
      "The address on the document doesn’t match the address on the account. Please verify and correct the provided address on the account, or upload a document with address that matches the account."
    when "verification_failed_document_match"
      "The information on the account couldn’t be verified. Please either upload a document to confirm the account details, or update the information on your account."
    when "verification_failed_id_number_match"
      "The ID number on the document doesn’t match the ID number on the account. Please verify and correct the provided ID number on the account, or upload a document with ID number that matches the account."
    when "verification_failed_keyed_identity"
      "The identity information you entered cannot be verified. Please correct any errors or upload a document that matches the identity fields (e.g., name and date of birth) that you entered."
    when "verification_failed_keyed_match"
      "The information on the account couldn’t be verified. Please either upload a document to confirm the account details, or update the information on your account."
    when "verification_failed_name_match"
      "The name on the document doesn’t match the name on the account. Please verify and correct the provided name on the account, or upload a document with name that matches the account."
    when "verification_failed_other"
      "There was a problem with your identity verification."
    when "verification_failed_residential_address"
      "We could not verify that the person resides at the provided address. The address must be a valid physical address where the individual resides and cannot be a P.O. Box."
    when "verification_failed_tax_id_match"
      "The tax ID that you provided couldn’t be verified with the IRS. Please correct any possible errors in the company name or tax ID, or upload a document that contains those fields."
    when "verification_failed_tax_id_not_issued"
      "The tax ID that you provided couldn’t be verified with the IRS. Please correct any possible errors in the company name or tax ID, or upload a document that contains those fields."
    when "verification_missing_directors"
      "We have identified directors that haven’t been added on the account. Add any missing directors to the account."
    when "verification_missing_executives"
      "We have identified executives that haven’t been added on the account. Add any missing executives to the account."
    when "verification_missing_owners"
      "We have identified owners that haven’t been added on the account. Add any missing owners to the account."
    when "verification_requires_additional_memorandum_of_associations"
      "We have identified holding companies with significant percentage ownership. Upload a Memorandum of Association for each of the holding companies."
    end
  end
end
