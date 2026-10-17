# frozen_string_literal: true

Premailer::Rails.config[:remove_ids] = false
Premailer::Rails.config[:preserve_style_attribute] = true

Rails.application.config.to_prepare do
  # Replaces the gem default, whose :network strategy fetches any seller href with a bare Net::HTTP.get.
  Premailer::Rails.config[:strategies] = [EmailStylesheetLoader]
end

# Once at boot rather than in to_prepare, so a code reload does not stack a second prepend.
Rails.application.config.after_initialize do
  Premailer::Rails::CSSHelper.cache = EmailStylesheetLoader::Cache.new
  Premailer::Rails::CSSHelper.singleton_class.prepend(EmailStylesheetLoader::DocumentDeadline)
end
