# frozen_string_literal: true

# Scans bot-generated content for tags like [[ENVIAR_BROCHURA]] and resolves
# them into attachments to be sent as extra messages after the text.
#
# Tag → attachment mapping lives in `agent_bot.bot_config["attachment_tags"]`:
#
#   {
#     "ENVIAR_BROCHURA": {
#       "url": "https://.../plano.pdf",
#       "type": "file",              # file | image | audio | video
#       "filename": "plano.pdf",     # optional; derived from URL if omitted
#       "content_type": "application/pdf"  # optional; guessed from extension if omitted
#     },
#     "ENVIAR_LOGO": { "url": "...", "type": "image" }
#   }
#
# Backwards compatibility: if `attachment_tags` is absent and the legacy
# `pre_transfer_attachment_url` is set, the tag [[ENVIAR_BROCHURA]] still
# resolves to that URL as a `file`.
class AgentBots::TagProcessor
  TAG_PATTERN = /\[\[([A-Z][A-Z0-9_]*)\]\]/.freeze
  LEGACY_TAG  = 'ENVIAR_BROCHURA'

  ALLOWED_TYPES = %w[file image audio video].freeze

  CONTENT_TYPE_BY_EXT = {
    'pdf'  => 'application/pdf',
    'png'  => 'image/png',
    'jpg'  => 'image/jpeg',
    'jpeg' => 'image/jpeg',
    'gif'  => 'image/gif',
    'webp' => 'image/webp',
    'mp3'  => 'audio/mpeg',
    'ogg'  => 'audio/ogg',
    'm4a'  => 'audio/mp4',
    'wav'  => 'audio/wav',
    'mp4'  => 'video/mp4',
    'webm' => 'video/webm',
    'doc'  => 'application/msword',
    'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls'  => 'application/vnd.ms-excel',
    'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
  }.freeze

  Attachment = Struct.new(:tag, :url, :file_type, :filename, :content_type, keyword_init: true)

  def initialize(agent_bot)
    @agent_bot = agent_bot
  end

  # Returns { clean_content: String, attachments: [Attachment] }.
  # Repeated tags send the attachment once. Unknown or misconfigured tags are
  # left in the text on purpose, so the mistake surfaces instead of silent loss.
  def process(content)
    return { clean_content: content, attachments: [] } if content.blank?

    seen        = {}
    attachments = []
    clean       = content.dup

    content.scan(TAG_PATTERN).each do |(tag)|
      next if seen[tag]

      att = resolve(tag)
      next unless att

      seen[tag] = true
      attachments << att
      clean = clean.gsub("[[#{tag}]]", '')
    end

    clean = clean.gsub(/\n{3,}/, "\n\n").strip

    { clean_content: clean, attachments: attachments }
  end

  private

  def resolve(tag)
    @resolved ||= {}
    return @resolved[tag] if @resolved.key?(tag)

    @resolved[tag] = resolve!(tag)
  end

  def resolve!(tag)
    config = tag_configs[tag] || legacy_config_for(tag)
    return nil if config.blank?

    url = config['url'].to_s
    return nil if url.blank?

    file_type = normalize_type(config['type'])
    filename  = config['filename'].presence || derive_filename(url)
    content_type = config['content_type'].presence || guess_content_type(filename)

    Attachment.new(
      tag:          tag,
      url:          url,
      file_type:    file_type,
      filename:     filename,
      content_type: content_type
    )
  end

  def tag_configs
    @tag_configs ||= (@agent_bot.bot_config&.dig('attachment_tags') || {})
  end

  def legacy_config_for(tag)
    return nil unless tag == LEGACY_TAG

    url = @agent_bot.bot_config&.dig('pre_transfer_attachment_url')
    return nil if url.blank?

    { 'url' => url, 'type' => 'file' }
  end

  def normalize_type(type)
    type = type.to_s.downcase
    ALLOWED_TYPES.include?(type) ? type : 'file'
  end

  def derive_filename(url)
    base = url.split('?').first.to_s.split('/').last
    base.presence || 'arquivo'
  end

  def guess_content_type(filename)
    ext = filename.to_s.split('.').last.to_s.downcase
    CONTENT_TYPE_BY_EXT[ext] || 'application/octet-stream'
  end
end
