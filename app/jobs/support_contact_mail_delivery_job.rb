# frozen_string_literal: true

# The arguments carry the submitter's message and up to 6 MB of base64
# screenshots, which ActiveJob would otherwise write to the info log on both
# enqueue and perform.
class SupportContactMailDeliveryJob < MailDeliveryJob
  self.log_arguments = false
end
