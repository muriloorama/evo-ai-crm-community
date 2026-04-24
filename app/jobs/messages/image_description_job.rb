class Messages::ImageDescriptionJob < ApplicationJob
  queue_as :low

  def perform(attachment_id)
    attachment = Accountable.as_super_admin { Attachment.find_by(id: attachment_id) }
    unless attachment
      Rails.logger.warn "ImageDescriptionJob: Attachment not found: #{attachment_id}"
      return
    end

    unless attachment.image?
      Rails.logger.info "ImageDescriptionJob: Attachment #{attachment_id} is not image (type: #{attachment.file_type})"
      return
    end

    msg = attachment.message
    unless msg&.incoming?
      Rails.logger.info "ImageDescriptionJob: Attachment #{attachment_id} message is not incoming"
      return
    end

    Accountable.with_account(msg.account_id) do
      Rails.logger.info "ImageDescriptionJob: Starting description for attachment #{attachment_id}"
      result = Messages::ImageDescriptionService.new(attachment: attachment).perform

      if result[:error]
        Rails.logger.warn "ImageDescriptionJob: Failed for attachment #{attachment_id}: #{result[:error]}"
      elsif result[:success]
        Rails.logger.info "ImageDescriptionJob: Description saved for attachment #{attachment_id}"
      end
    end
  rescue StandardError => e
    Rails.logger.error "ImageDescriptionJob: Error processing attachment #{attachment_id}: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
  end
end
