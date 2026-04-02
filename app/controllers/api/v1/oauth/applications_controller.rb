# frozen_string_literal: true

class Api::V1::Oauth::ApplicationsController < Api::BaseController
  before_action :authenticate_user!

  def create
    client_id = params[:client_id]
    redirect_uri = params[:redirect_uri]

    unless client_id && redirect_uri
      render json: { error: 'Missing required parameters' }, status: :bad_request
      return
    end

    begin
      # Verificar se é uma aplicação RFC 7591 existente
      existing_app = OauthApplication.find_by(uid: client_id)
      
      if existing_app&.rfc7591_registered?
        # Single-tenant: no account binding needed
        Rails.logger.debug "RFC 7591: Application #{existing_app.name} ready" if Rails.env.development?

        render json: {
          message: 'Application ready',
          application_id: existing_app.id
        }
      else
        # Criar nova aplicação dinâmica
        application = DynamicOauthService.create_or_find_application_for_account(
          client_id,
          current_user,
          redirect_uri
        )

        unless application
          render json: { error: 'Failed to create OAuth application' }, status: :unprocessable_entity
          return
        end

        Rails.logger.debug "Dynamic OAuth: Created application #{application.name}" if Rails.env.development?

        render json: {
          message: 'Application created successfully',
          application_id: application.id
        }
      end
    rescue => e
      Rails.logger.error "❌ OAuth Application Creation Error: #{e.message}"
      render json: { error: 'Failed to process OAuth application' }, status: :internal_server_error
    end
  end
end