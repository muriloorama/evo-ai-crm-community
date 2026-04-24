# frozen_string_literal: true

module Whatsapp
  module Providers
    class WhatsappCloudService < Whatsapp::Providers::BaseService
      include Whatsapp::Providers::Concerns::TemplateSync
      class AudioUploadError < StandardError; end
      
      def send_message(phone_number, message)
        @message = message

        if message.attachments.present?
          send_attachment_message(phone_number, message)
        elsif message.content_type == 'input_select'
          send_interactive_text_message(phone_number, message)
        else
          send_text_message(phone_number, message)
        end
      end

      def send_template(phone_number, template_info)
        response = HTTParty.post(
          "#{phone_id_path}/messages",
          headers: api_headers,
          body: {
            messaging_product: 'whatsapp',
            **build_recipient_field(phone_number),
            template: template_body_parameters(template_info),
            type: 'template'
          }.to_json
        )

        process_response(response)
      end

      def sync_templates
        templates = fetch_whatsapp_templates("#{business_account_path}/message_templates?access_token=#{whatsapp_channel.provider_config['api_key']}")
        return if templates.blank?

        templates.each do |template_data|
          sync_template_to_database(template_data)
        end
      rescue StandardError => e
        Rails.logger.error "WhatsApp Cloud sync_templates error: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
      end

      def subscribe_to_webhooks
        return if whatsapp_channel.provider_config['waba_id'].blank?

        HTTParty.post(
          "#{api_base_path}/v23.0/#{whatsapp_channel.provider_config['waba_id']}/subscribed_apps",
          headers: api_headers
        )
      end

      def unsubscribe_from_webhooks
        return if whatsapp_channel.provider_config['waba_id'].blank?

        HTTParty.delete(
          "#{api_base_path}/v23.0/#{whatsapp_channel.provider_config['waba_id']}/subscribed_apps",
          headers: api_headers
        )
      end

      def fetch_whatsapp_templates(url)
        response = HTTParty.get(url)
        return [] unless response.success?

        next_url = next_url(response)

        return response['data'] + fetch_whatsapp_templates(next_url) if next_url.present?

        response['data']
      end

      def next_url(response)
        response['paging'] ? response['paging']['next'] : ''
      end

      def validate_provider_config?
        url = "#{business_account_path}/message_templates?access_token=#{whatsapp_channel.provider_config['api_key']}"
        Rails.logger.info "WhatsApp Cloud validation URL: #{url}"
        Rails.logger.info "WhatsApp Cloud provider_config: #{whatsapp_channel.provider_config.inspect}"

        response = HTTParty.get(url)

        Rails.logger.info "WhatsApp Cloud validation response status: #{response.code}"
        Rails.logger.info "WhatsApp Cloud validation response body: #{response.body}"

        response.success?
      end

      def api_headers
        { 'Authorization' => "Bearer #{whatsapp_channel.provider_config['api_key']}",
          'Content-Type' => 'application/json' }
      end

      def media_url(media_id)
        "#{api_base_path}/v23.0/#{media_id}"
      end

      def api_base_path
        ENV.fetch('WHATSAPP_CLOUD_BASE_URL', 'https://graph.facebook.com')
      end

      # TODO: See if we can unify the API versions and for both paths and make it consistent with out facebook app API versions
      def phone_id_path
        "#{api_base_path}/v23.0/#{whatsapp_channel.provider_config['phone_number_id']}"
      end

      def business_account_path
        # Use waba_id for accessing message_templates, fallback to business_account_id for backward compatibility
        waba_id = whatsapp_channel.provider_config['waba_id'] || whatsapp_channel.provider_config['business_account_id']
        "#{api_base_path}/v23.0/#{waba_id}"
      end

      def send_text_message(phone_number, message)
        response = HTTParty.post(
          "#{phone_id_path}/messages",
          headers: api_headers,
          body: {
            messaging_product: 'whatsapp',
            context: whatsapp_reply_context(message),
            **build_recipient_field(phone_number),
            text: { body: html_to_whatsapp(message.content) },
            type: 'text'
          }.to_json
        )

        process_response(response)
      end

      # Sends a reaction emoji to an existing WhatsApp message.
      # Passing an empty emoji removes the reaction on the contact's side.
      # ref: https://developers.facebook.com/docs/whatsapp/cloud-api/guides/send-message-reactions
      def send_reaction(phone_number, target_source_id, emoji)
        response = HTTParty.post(
          "#{phone_id_path}/messages",
          headers: api_headers,
          body: {
            messaging_product: 'whatsapp',
            **build_recipient_field(phone_number),
            type: 'reaction',
            reaction: {
              message_id: target_source_id,
              emoji: emoji.to_s
            }
          }.to_json
        )

        process_response(response)
      end

      def send_attachment_message(phone_number, message)
        # Meta Cloud API sends one media per HTTP call, so iterate through all
        # attachments instead of only dispatching the first.
        responses = message.attachments.map do |attachment|
          type = %w[image audio video].include?(attachment.file_type) ? attachment.file_type : 'document'

          if type == 'audio'
            send_audio_via_media_upload(phone_number, message, attachment)
          else
            send_attachment_via_link(phone_number, message, attachment, type)
          end
        end
        # Return the last message id so the caller still gets a valid reference;
        # individual sends log their own failures.
        responses.last
      end

      def error_message(response)
        # https://developers.facebook.com/docs/whatsapp/cloud-api/support/error-codes/#sample-response
        response.parsed_response&.dig('error', 'message')
      end

      def template_body_parameters(template_info)
        payload = {
          name: template_info[:name],
          language: {
            policy: 'deterministic',
            code: template_info[:lang_code]
          }
        }

        components = build_template_components(template_info)
        payload[:components] = components if components.any?
        payload
      end

      # Builds the `components` array Meta expects on every template send.
      # - HEADER is only attached for media headers (IMAGE/VIDEO/DOCUMENT),
      #   which require a link to the example asset used at approval time.
      # - BODY is only attached when at least one variable is substituted.
      # - BUTTONS are attached only for URL buttons whose url contains a
      #   `{{n}}` placeholder — static buttons don't need parameters.
      # Text-only header + static buttons are taken from the approved
      # template structure and don't need to be repeated in the payload.
      def build_template_components(template_info)
        body_parameters = Array(template_info[:parameters]).compact
        stored_components = template_info[:components] || {}
        stored_components = stored_components.with_indifferent_access if stored_components.respond_to?(:with_indifferent_access)

        components = []
        header_component = build_header_component(stored_components[:header])
        components << header_component if header_component
        components << { type: 'body', parameters: body_parameters } if body_parameters.any?
        components.concat(build_button_components(stored_components[:buttons]))
        components
      end

      def build_header_component(header)
        return unless header

        format = header[:format].to_s.downcase
        return unless %w[image video document].include?(format)

        media_url = header[:url] || header.dig(:example, :header_handle)&.first ||
                    template_info_header_media_url(header)
        return if media_url.blank?

        media_payload = { link: media_url }
        media_payload[:filename] = header[:filename] if format == 'document' && header[:filename].present?

        { type: 'header', parameters: [{ type: format, format.to_sym => media_payload }] }
      end

      def template_info_header_media_url(header)
        example = header[:example]
        return if example.blank?

        # Meta stores media samples under header_handle (array of URLs).
        Array(example[:header_handle] || example['header_handle']).first
      end

      def build_button_components(buttons_section)
        return [] unless buttons_section

        buttons_array = buttons_section.is_a?(Array) ? buttons_section : Array(buttons_section[:buttons])
        buttons_array.each_with_index.map do |btn, idx|
          next unless btn
          type = (btn[:type] || btn['type']).to_s.upcase
          url = btn[:url] || btn['url']
          # Only URL buttons with a `{{n}}` placeholder require a parameter.
          next unless type == 'URL' && url.to_s.include?('{{')

          placeholder = url[/\{\{(\d+)\}\}/, 1].to_i - 1
          dynamic_value = Array(template_info_button_params)[placeholder] ||
                          (btn[:example] || btn['example']).to_s
          {
            type: 'button',
            sub_type: 'url',
            index: idx.to_s,
            parameters: [{ type: 'text', text: dynamic_value.to_s }]
          }
        end.compact
      end

      # Placeholder hook — today the chat doesn't send per-button params;
      # extend here when the frontend starts sending them.
      def template_info_button_params
        []
      end

      def whatsapp_reply_context(message)
        reply_to = message.content_attributes[:in_reply_to_external_id]
        return nil if reply_to.blank?

        {
          message_id: reply_to
        }
      end

      def send_interactive_text_message(phone_number, message)
        payload = create_payload_based_on_items(message)

        response = HTTParty.post(
          "#{phone_id_path}/messages",
          headers: api_headers,
          body: {
            messaging_product: 'whatsapp',
            **build_recipient_field(phone_number),
            interactive: payload,
            type: 'interactive'
          }.to_json
        )

        process_response(response)
      end

      def create_template(template_data)
        Rails.logger.info "WhatsApp Cloud create_template request URL: #{business_account_path}/message_templates"
        Rails.logger.info "WhatsApp Cloud create_template request headers: #{api_headers.inspect}"

        # Processar componentes para adicionar examples quando necessário
        processed_components = process_template_components(template_data['components'])

        request_body = {
          name: template_data['name'],
          category: template_data['category'],
          language: template_data['language'],
          components: processed_components
        }

        # Adicionar message_send_ttl_seconds apenas se fornecido
        if template_data['message_send_ttl_seconds'].present?
          request_body[:message_send_ttl_seconds] =
            template_data['message_send_ttl_seconds']
        end

        Rails.logger.info "WhatsApp Cloud create_template request body: #{request_body.to_json}"

        # Garantir encoding UTF-8 correto
        json_body = ensure_utf8_encoding(request_body.to_json)

        response = HTTParty.post(
          "#{business_account_path}/message_templates",
          headers: api_headers,
          body: json_body
        )

        Rails.logger.info "WhatsApp Cloud create_template response status: #{response.code}"
        Rails.logger.info "WhatsApp Cloud create_template response body: #{response.body}"

        unless response.success?
          error_details = parse_whatsapp_error(response)
          Rails.logger.error "WhatsApp template creation failed: #{error_details}"
          raise StandardError, error_details
        end

        # Atualizar a lista de templates após criar um novo
        sync_templates
        whatsapp_channel.message_templates.find { |template| template['name'] == template_data['name'] }
      end

      def update_template(template_id, template_data)
        Rails.logger.info '=== UPDATE WHATSAPP TEMPLATE START ==='
        Rails.logger.info "WhatsApp Cloud update_template template_id: #{template_id}"
        Rails.logger.info "WhatsApp Cloud update_template template_data: #{template_data.inspect}"

        template = find_template_by_id(template_id)
        validate_template_editable(template)

        # Para editar templates, usar o endpoint específico do template
        update_url = "#{api_base_path}/v23.0/#{template_id}"
        Rails.logger.info "WhatsApp Cloud update_template request URL: #{update_url}"
        Rails.logger.info "WhatsApp Cloud update_template request headers: #{api_headers.inspect}"

        request_body = build_update_request_body(template, template_data)
        validate_update_request_body(request_body)

        Rails.logger.info "WhatsApp Cloud update_template request body: #{request_body.to_json}"

        response = send_update_request(update_url, request_body)
        handle_update_response(response, template_id)
      end

      def delete_template(template_id)
        Rails.logger.info '=== DELETE WHATSAPP TEMPLATE START ==='
        Rails.logger.info "WhatsApp Cloud delete_template template_id: #{template_id}"

        template = whatsapp_channel.message_templates.find { |t| t['id'] == template_id }
        if template.blank?
          Rails.logger.warn "Template not found with ID: #{template_id}, considering as already deleted"
          return true
        end

        Rails.logger.info "Found template to delete: #{template['name']} (#{template['language']})"
        Rails.logger.info "WhatsApp Cloud delete_template request URL: #{business_account_path}/message_templates"
        Rails.logger.info "WhatsApp Cloud delete_template request headers: #{api_headers.inspect}"

        request_body = { name: template['name'] }
        Rails.logger.info "WhatsApp Cloud delete_template request body: #{request_body.to_json}"

        response = HTTParty.delete(
          "#{business_account_path}/message_templates",
          headers: api_headers,
          body: request_body.to_json
        )

        handle_delete_response(response)
      end

      private

      def build_recipient_field(phone_or_bsuid)
        if phone_or_bsuid.present? && phone_or_bsuid.match?(RegexHelper::BSUID_REGEX)
          { recipient: phone_or_bsuid }
        else
          { to: phone_or_bsuid }
        end
      end

      # Send audio message via media upload endpoint with voice: true
      def send_audio_via_media_upload(phone_number, message, attachment)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        mime_type = detect_attachment_mime_type(attachment)
        filename = attachment.file.filename.to_s
        Rails.logger.info(
          "Sending audio via media upload for message #{message.id} " \
          "(mime_type=#{mime_type}, filename=#{filename})"
        )

        # Download attachment to temporary file
        temp_file = download_attachment_to_temp(attachment)

        begin
          # Upload original audio to WhatsApp Media API (no backend transcoding)
          media_id = upload_media_to_whatsapp(temp_file.path, mime_type)
          return if media_id.blank?

          # Send message with media_id and voice: true
          response = HTTParty.post(
            "#{phone_id_path}/messages",
            headers: api_headers,
            body: {
              messaging_product: 'whatsapp',
              context: whatsapp_reply_context(message),
              **build_recipient_field(phone_number),
              type: 'audio',
              audio: {
                id: media_id,
                voice: true
              }
            }.to_json
          )

          process_response(response)
        rescue AudioUploadError => e
          mark_audio_upload_failed(message, e.message)
          nil
        ensure
          # Clean up temporary file
          File.delete(temp_file.path) if temp_file && File.exist?(temp_file.path)

          duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
          Rails.logger.info("WhatsApp Cloud audio send finished message_id=#{message.id} duration_ms=#{duration_ms}")
        end
      end

      # Send non-audio attachments via link (existing behavior)
      def send_attachment_via_link(phone_number, message, attachment, type)
        type_content = {
          'link': attachment.download_url
        }
        type_content['caption'] = html_to_whatsapp(message.content.to_s) unless %w[audio sticker].include?(type)
        type_content['filename'] = attachment.file.filename if type == 'document'

        response = HTTParty.post(
          "#{phone_id_path}/messages",
          headers: api_headers,
          body: {
            messaging_product: 'whatsapp',
            context: whatsapp_reply_context(message),
            **build_recipient_field(phone_number),
            type: type,
            type.to_sym => type_content
          }.to_json
        )

        process_response(response)
      end

      # Download ActiveStorage attachment to temporary file
      def download_attachment_to_temp(attachment)
        require 'tempfile'

        temp_file = Tempfile.new(['audio', File.extname(attachment.file.filename.to_s)])
        temp_file.binmode

        # Download blob content
        attachment.file.blob.download do |chunk|
          temp_file.write(chunk)
        end

        temp_file.rewind
        temp_file
      end

      # Upload media file to WhatsApp Cloud API
      # Returns media_id for use in messages
      def upload_media_to_whatsapp(file_path, content_type)
        Rails.logger.info "Uploading media to WhatsApp: #{file_path} (mime_type=#{content_type})"

        # Prepare multipart form data
        response = File.open(file_path, 'rb') do |file_io|
          HTTParty.post(
            "#{phone_id_path}/media",
            headers: { 'Authorization' => "Bearer #{whatsapp_channel.provider_config['api_key']}" },
            multipart: true,
            body: {
              messaging_product: 'whatsapp',
              type: content_type,
              file: file_io
            }
          )
        end

        Rails.logger.info "Media upload response: #{response.code} - #{response.body}"

        unless response.success?
          error_details = parse_whatsapp_error(response)
          prefixed_error = "WHATSAPP_CLOUD_AUDIO_UPLOAD_FAILED - #{error_details}"
          Rails.logger.error "Media upload failed: #{prefixed_error}"
          raise AudioUploadError, prefixed_error
        end

        media_id = response.parsed_response['id']
        Rails.logger.info "Media uploaded successfully: #{media_id}"
        media_id
      end

      def detect_attachment_mime_type(attachment)
        attachment&.file&.blob&.content_type.presence || 'application/octet-stream'
      end

      def mark_audio_upload_failed(message, error_message)
        Rails.logger.error("WhatsApp Cloud audio send failed for message #{message.id}: #{error_message}")
        return if message.blank?

        message.external_error = error_message
        message.status = :failed
        message.save!
      end

      def find_template_by_id(template_id)
        template = whatsapp_channel.message_templates.find { |t| t['id'] == template_id }
        if template.blank?
          Rails.logger.error "Template not found with ID: #{template_id}"
          raise StandardError, "Template not found with ID: #{template_id}"
        end
        template
      end

      def validate_template_editable(template)
        Rails.logger.info "Found template: #{template['name']} (#{template['language']}) - Status: #{template['status']}"

        editable_statuses = %w[APPROVED REJECTED PAUSED]
        return if editable_statuses.include?(template['status'])

        error_msg = "Template cannot be edited. Current status: #{template['status']}. " \
                    'Only templates with status APPROVED, REJECTED, or PAUSED can be edited.'
        Rails.logger.error error_msg
        raise StandardError, error_msg
      end

      def build_update_request_body(template, template_data)
        request_body = {}

        # Só incluir category se foi fornecida e é diferente da atual
        if template_data['category'].present? && template_data['category'] != template['category']
          if template['status'] == 'APPROVED'
            Rails.logger.warn 'Cannot change category of approved template. Skipping category update.'
          else
            request_body[:category] = template_data['category']
          end
        end

        # Sempre incluir components se fornecidos
        if template_data['components'].present?
          processed_components = process_template_components(template_data['components'])
          request_body[:components] = processed_components
        end

        # Adicionar message_send_ttl_seconds apenas se fornecido
        if template_data['message_send_ttl_seconds'].present?
          request_body[:message_send_ttl_seconds] =
            template_data['message_send_ttl_seconds']
        end

        request_body
      end

      def validate_update_request_body(request_body)
        return unless request_body.empty?

        error_msg = 'No valid fields to update. You can only update category (for non-approved templates) and components.'
        Rails.logger.warn error_msg
        raise StandardError, error_msg
      end

      def send_update_request(update_url, request_body)
        json_body = ensure_utf8_encoding(request_body.to_json)

        HTTParty.post(
          update_url,
          headers: api_headers,
          body: json_body
        )
      end

      def handle_update_response(response, template_id)
        Rails.logger.info "WhatsApp Cloud update_template response status: #{response.code}"
        Rails.logger.info "WhatsApp Cloud update_template response body: #{response.body}"

        unless response.success?
          error_details = parse_whatsapp_error(response)
          Rails.logger.error "WhatsApp template update failed: #{error_details}"

          # Tratar erro específico de conteúdo existente no idioma
          if response.body.include?('2388024') || response.body.include?('existe conte')
            error_msg = 'Cannot update template: Content already exists in this language. ' \
                        'WhatsApp templates with the same name and language cannot be modified. ' \
                        'Consider creating a new template with a different name.'
            raise StandardError, error_msg
          end

          raise StandardError, error_details
        end

        # Atualizar a lista de templates após a atualização
        Rails.logger.info 'Syncing templates after update...'
        sync_templates
        updated_template = whatsapp_channel.message_templates.find { |t| t['id'] == template_id }
        Rails.logger.info '=== UPDATE WHATSAPP TEMPLATE END ==='
        updated_template
      end

      def handle_delete_response(response)
        Rails.logger.info "WhatsApp Cloud delete_template response status: #{response.code}"
        Rails.logger.info "WhatsApp Cloud delete_template response body: #{response.body}"

        unless response.success?
          error_details = parse_whatsapp_error(response)
          Rails.logger.error "WhatsApp template deletion failed: #{error_details}"
          raise StandardError, error_details
        end

        Rails.logger.info 'Syncing templates after delete...'
        sync_templates
        Rails.logger.info '=== DELETE WHATSAPP TEMPLATE END ==='
        true
      end

      def process_template_components(components)
        return [] if components.blank?

        components.map do |component|
          processed_component = component.dup

          case component['type']
          when 'HEADER'
            # Se o texto do header contém variáveis {{1}}, adicionar example
            if component['format'] == 'TEXT' && component['text'].present? && component['text'].include?('{{')
              processed_component['example'] = {
                'header_text' => [component['text'].gsub(/\{\{\d+\}\}/, 'Example')]
              }
            end
          when 'BODY'
            if component['text'].present? && component['text'].include?('{{')
              # Se o texto do body contém variáveis, adicionar example
              example_text = component['text'].gsub(/\{\{\d+\}\}/, 'Example')
              processed_component['example'] = {
                'body_text' => [[example_text]]
              }
            end
          when 'BUTTONS'
            # Processar botões se necessário
            if component['buttons'].present?
              processed_component['buttons'] = component['buttons'].map do |button|
                process_button_component(button)
              end
            end
          end

          processed_component
        end
      end

      def process_button_component(button)
        processed_button = button.dup

        case button['type']
        when 'URL'
          if button['url'].present? && button['url'].include?('{{')
            # Para botões URL com variáveis, adicionar example
            processed_button['example'] = [button['url'].gsub(/\{\{\d+\}\}/, 'example')]
          end
        when 'PHONE_NUMBER'
          # Garantir que phone_number está no formato correto
          if button['phone_number'].present? && !button['phone_number'].start_with?('+')
            processed_button['phone_number'] =
              "+#{button['phone_number']}"
          end
        end

        processed_button
      end

      def parse_whatsapp_error(response)
        begin
          error_data = response.parsed_response
          if error_data && error_data['error']
            error_info = error_data['error']
            message = error_info['message'] || 'Unknown error'
            error_code = error_info['code'] || response.code
            error_subcode = error_info['error_subcode']

            error_details = "WhatsApp API Error (#{error_code})"
            error_details += " - Subcode: #{error_subcode}" if error_subcode
            error_details += " - #{message}"

            return error_details
          end
        rescue StandardError => e
          Rails.logger.error "Error parsing WhatsApp response: #{e.message}"
        end

        "Error creating template. Status: #{response.code}, Body: #{response.body}"
      end

      def ensure_utf8_encoding(json_string)
        # Garantir que a string está em UTF-8 e é válida
        json_string.force_encoding('UTF-8')

        # Verificar se a string é válida UTF-8
        unless json_string.valid_encoding?
          # Se não for válida, tentar corrigir removendo caracteres inválidos
          json_string = json_string.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
        end

        json_string
      end
    end
  end
end
