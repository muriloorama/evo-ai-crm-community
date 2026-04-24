require 'base64'
require 'tempfile'

module Whatsapp::EvolutionHandlers::MessagesUpsert
  include Whatsapp::EvolutionHandlers::Helpers
  include Whatsapp::EvolutionHandlers::AttachmentProcessor
  include Whatsapp::EvolutionHandlers::FileExtensions
  include Whatsapp::EvolutionHandlers::ContentHandlers
  include EvolutionHelper

  private

  def process_messages_upsert
    # Evolution API v2.3.1 sends single message data directly in 'data' field
    message_data = processed_params[:data]
    return if message_data.blank?

    @message = nil
    @contact_inbox = nil
    @contact = nil
    @raw_message = message_data

    Rails.logger.info "Evolution API: Processing message #{raw_message_id} (fromMe: #{!incoming?})"

    if incoming?
      handle_message
    else
      # Handle outgoing messages with lock to avoid race conditions
      with_evolution_channel_lock_on_outgoing_message(inbox.channel.id) { handle_message }
    end
  end

  def handle_message
    return unless message_processable?

    Rails.logger.info "Evolution API: Creating new message #{raw_message_id}"

    cache_message_source_id_in_redis
    set_contact

    unless @contact
      clear_message_source_id_from_redis
      Rails.logger.warn "Evolution API: Contact not found for message: #{raw_message_id}"
      return
    end

    set_conversation
    update_conversation_status_if_needed
    handle_create_message
    clear_message_source_id_from_redis
  end

  def set_contact
    push_name = contact_name
    raw_source_id = phone_number_from_jid

    # Always normalize Brazilian numbers to the 9-digit format.
    # processed_waid only helps when a contact_inbox already exists; it misses contacts
    # created manually in the CRM (Contact record exists, but no ContactInbox yet).
    # By normalizing unconditionally, find_contact_by_phone_number can also match them.
    source_id = brazil_phone_number?(raw_source_id) ? normalised_brazil_mobile_number(raw_source_id) : raw_source_id

    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: source_id,
      inbox: inbox,
      contact_attributes: {
        name: push_name,
        phone_number: "+#{source_id}"
      }
    ).perform

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact

    # Update contact name if it was just the phone number
    @contact.update!(name: push_name) if @contact.name == raw_source_id && push_name.present?
  end

  def phone_number_string?(value)
    value.present? && value.match?(/^\+?\d{7,15}$/)
  end

  def handle_create_message
    create_message(attach_media: media_attachment?)
  end

  def create_message(attach_media: false)
    build_message_attributes
    handle_attach_media if attach_media
    handle_location if message_type == 'location'
    handle_contacts if message_type == 'contacts'
    save_message_and_notify
  end

  def build_message_attributes
    # Outgoing messages that arrive via webhook (with no matching CRM-dispatched
    # message) are echoes of the operator sending from the WhatsApp client on
    # their phone. We mark them with `external_origin: true` so the UI can
    # show a "Celular" badge instead of attributing the message to the random
    # User.first / first SuperAdmin we used as a placeholder sender (a NOT NULL
    # constraint forces us to set one, but it doesn't reflect reality).
    attrs = message_content_attributes
    attrs[:external_origin] = true unless incoming?

    @message = @conversation.messages.build(
      content: message_content || '',
      inbox_id: @inbox.id,
      source_id: raw_message_id,
      sender: incoming? ? @contact : User.where(type: 'SuperAdmin').first || User.first,
      sender_type: incoming? ? 'Contact' : 'User',
      message_type: incoming? ? :incoming : :outgoing,
      content_attributes: attrs
    )
  end

  def save_message_and_notify
    @message.save!

    Rails.logger.info "Evolution API: Message created successfully - ID: #{@message.id}, Content: #{@message.content&.truncate(100)}"

    inbox.channel.received_messages([@message], @conversation) if incoming?
  end

  def message_processable?
    return false if jid_type != 'user'
    return false if ignore_message?
    return false if find_message_by_source_id(raw_message_id) || message_under_process?

    true
  end

  def update_conversation_status_if_needed
    return unless !incoming? && @conversation&.status == 'pending'

    # Any outgoing webhook message that reaches here is, by definition,
    # NOT a CRM-dispatched message (those are deduped earlier by
    # message_processable?). So this is an echo of the operator typing from
    # their own WhatsApp client — a human takeover. Flip to `open` so the
    # AgentBotInbox (which only auto-replies on `pending`) stops responding.
    @conversation.update!(status: :open)
    if @conversation.inbox.active_bot?
      Rails.logger.info "Evolution API: Human takeover — phone echo moved conversation #{@conversation.id} to open (bot paused)"
    else
      Rails.logger.info "Evolution API: Updated conversation #{@conversation.id} status from pending to open for outgoing message"
    end
  end
end
