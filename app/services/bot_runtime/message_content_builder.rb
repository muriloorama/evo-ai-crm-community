# frozen_string_literal: true

module BotRuntime
  # Builds the text payload sent to the bot runtime (and downstream to the
  # LLM) from a Message. Expands attachments into markers so the model
  # understands the customer sent media even when the model itself can't
  # process binary payloads, and inlines Whisper transcriptions for audio.
  #
  # This is called from two points to guarantee we pick up async-completed
  # transcriptions:
  #   1. `DelegationService` (when serializing the event)
  #   2. `SendEventJob#perform` (right before the HTTP call to bot-runtime)
  module MessageContentBuilder
    MEDIA_PLACEHOLDERS = {
      'audio'    => '[O cliente enviou um áudio]',
      'image'    => '[O cliente enviou uma imagem]',
      'video'    => '[O cliente enviou um vídeo]',
      'location' => '[O cliente enviou uma localização]',
      'file'     => '[O cliente enviou um arquivo/documento]',
      'contact'  => '[O cliente enviou um contato]'
    }.freeze

    HISTORY_WINDOW = 25 # previous messages to include as context

    module_function

    def build(message)
      return '' unless message

      message.reload rescue nil
      parts = []

      text = message.content.to_s.strip
      parts << text if text.present? && !auto_placeholder?(text)

      message.attachments.each do |att|
        parts << attachment_part(att)
      end

      current = parts.compact.join("\n").strip
      current = message.content.to_s if current.blank?

      prefix = recent_history_prefix(message)
      return current if prefix.blank?

      "#{prefix}\n\n[MENSAGEM ATUAL DO CLIENTE]\n#{current}"
    end

    # Builds a compact history prefix with the last N messages so the agent
    # always has conversation context — even if the processor lost its own
    # session (restart, TTL, or conversation reopened after being resolved).
    def recent_history_prefix(message)
      conversation = message.conversation
      return nil unless conversation

      scope = conversation.messages
                          .where.not(id: message.id)
                          .where.not(message_type: 'activity')

      reset_at_raw = conversation.additional_attributes&.dig('bot_reset_at')
      if reset_at_raw.present?
        reset_at = Time.parse(reset_at_raw) rescue nil
        scope = scope.where('messages.created_at > ?', reset_at) if reset_at
      end

      previous = scope.order(created_at: :asc).last(HISTORY_WINDOW)
      return nil if previous.empty?

      lines = previous.map do |m|
        role = if m.incoming?
                 'cliente'
               elsif m.sender_type == 'AgentBot'
                 'você (assistente)'
               elsif m.content_attributes&.dig('external_origin')
                 'atendente humano (pelo celular)'
               else
                 'atendente humano'
               end
        snippet = m.content.to_s.gsub(/\s+/, ' ').strip
        snippet = "#{snippet[0..200]}…" if snippet.length > 200
        snippet = '(mídia sem texto)' if snippet.blank?
        "[#{role}]: #{snippet}"
      end

      "[HISTÓRICO RECENTE DA CONVERSA — use apenas como contexto, NÃO responda a essas mensagens antigas]\n#{lines.join("\n")}"
    end

    def attachment_part(att)
      return nil unless att

      case att.file_type
      when 'audio'
        transcript = att.meta&.[]('transcribed_text').to_s.strip
        transcript.present? ? "[O cliente enviou um áudio — transcrição: \"#{transcript}\"]" : MEDIA_PLACEHOLDERS['audio']
      when 'image'
        description = att.meta&.[]('image_description').to_s.strip
        description.present? ? "[O cliente enviou uma imagem — descrição: \"#{description}\"]" : MEDIA_PLACEHOLDERS['image']
      else
        MEDIA_PLACEHOLDERS[att.file_type.to_s]
      end
    end

    # Heuristic: upstream services sometimes stuff 'Audio message', 'Image
    # message', etc. into `content` when attaching media. Those add no signal
    # for the model — strip them in favor of the explicit marker we emit.
    def auto_placeholder?(text)
      %w[
        Audio\ message Image\ message Video\ message Document\ message Sticker\ message Media\ message
      ].include?(text) || text.start_with?('[')
    end
  end
end
