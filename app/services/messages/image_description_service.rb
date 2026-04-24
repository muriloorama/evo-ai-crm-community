# frozen_string_literal: true

# Generates a short textual description of an image attachment using OpenAI's
# vision model (gpt-4o-mini). The description is stored on
# `attachment.meta['image_description']` and later picked up by
# `BotRuntime::MessageContentBuilder` so the LLM agent (which can't do vision
# itself in this deployment) has context about what the customer sent.
#
# Uses the same OpenAI API key resolution path as AudioTranscriptionService.
class Messages::ImageDescriptionService
  include Events::Types
  pattr_initialize [:attachment!]

  DEFAULT_MODEL  = 'gpt-4o-mini'
  DEFAULT_PROMPT = <<~PROMPT.strip
    Descreva objetivamente o conteúdo desta imagem em até 3 frases, em português.
    Foque no que é visível (objetos, produto, contexto). Não invente nada que não esteja na imagem.
  PROMPT

  def perform
    Rails.logger.info "ImageDescriptionService: start attachment=#{attachment.id}"

    unless attachment.image?
      return { error: 'Attachment is not image' }
    end

    if attachment.meta&.[]('image_description').present?
      return { error: 'Description already exists' }
    end

    api_key = openai_api_key
    unless api_key.present?
      Rails.logger.warn 'ImageDescriptionService: OpenAI API key not configured; skipping'
      return { error: 'OpenAI API key not configured' }
    end

    image_url = accessible_image_url
    unless image_url.present?
      Rails.logger.warn 'ImageDescriptionService: could not derive accessible URL for image'
      return { error: 'Image URL unavailable' }
    end

    description = call_openai_vision(api_key, image_url)
    return { error: 'Description failed' } unless description.present?

    attachment.meta ||= {}
    attachment.meta['image_description'] = description
    attachment.save!

    message = attachment.message
    attachment.reload
    message.reload
    message.association(:attachments).reset

    Rails.configuration.dispatcher.dispatch(
      MESSAGE_UPDATED,
      Time.zone.now,
      message: message,
      previous_changes: { 'attachments' => [attachment.id] }
    )

    Rails.logger.info "ImageDescriptionService: saved description (len=#{description.length}) for attachment=#{attachment.id}"
    { success: true, description: description }
  rescue StandardError => e
    Rails.logger.error "ImageDescriptionService: error #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
    { error: e.message }
  end

  private

  def openai_api_key
    global = GlobalConfigService.load('OPENAI_API_SECRET', nil)
    return global if global.present?

    Hook.find_by(app_id: 'openai')&.settings&.[]('api_key')
  end

  def accessible_image_url
    return nil unless attachment.file.attached?
    # download_url serves from ActiveStorage's service-URL (signed, public);
    # OpenAI needs a URL reachable from the public internet, so this works
    # with S3/CloudFront but NOT with a purely local-disk dev setup.
    attachment.download_url.presence || attachment.file_url.presence
  rescue StandardError => e
    Rails.logger.warn "ImageDescriptionService: url resolution failed: #{e.message}"
    nil
  end

  def call_openai_vision(api_key, image_url)
    require 'net/http'
    require 'uri'
    require 'json'

    base_url = GlobalConfigService.load('OPENAI_API_URL', 'https://api.openai.com/v1')
    uri = URI("#{base_url}/chat/completions")

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri.request_uri)
    request['Authorization'] = "Bearer #{api_key}"
    request['Content-Type']  = 'application/json'
    request.body = {
      model: DEFAULT_MODEL,
      messages: [
        {
          role: 'user',
          content: [
            { type: 'text', text: DEFAULT_PROMPT },
            { type: 'image_url', image_url: { url: image_url } }
          ]
        }
      ],
      max_tokens: 250
    }.to_json

    response = http.request(request)
    unless response.is_a?(Net::HTTPSuccess)
      Rails.logger.error "ImageDescriptionService: OpenAI HTTP #{response.code} - #{response.body&.truncate(300)}"
      return nil
    end

    body = JSON.parse(response.body)
    body.dig('choices', 0, 'message', 'content').to_s.strip.presence
  rescue StandardError => e
    Rails.logger.error "ImageDescriptionService: OpenAI call failed: #{e.message}"
    nil
  end
end
