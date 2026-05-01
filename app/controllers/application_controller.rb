class ApplicationController < ActionController::Base
  include RequestExceptionHandler
  include SwitchLocale
  include Pundit::Authorization

  skip_before_action :verify_authenticity_token, raise: false

  around_action :switch_locale
  around_action :handle_with_exception, unless: :skip_exception_handling?

  private

  def skip_exception_handling?
    # Skip exception handling for specific controllers if needed
    # Originally was checking for devise_controller? but Devise is not installed
    false
  end

  def pundit_user
    {
      user: Current.user,
      service_authenticated: Current.service_authenticated
    }
  end

  # Feature gate helpers used by feature/limit-aware controllers.
  # Both short-circuit with a render — caller should `return if performed?`
  # if it has further work to do, or place these in a `before_action`.

  # Renders 403 when the workspace has the feature explicitly disabled.
  # Defaults are wide-open, so existing tenants with `features={}` always
  # pass through.
  def ensure_feature!(key, label: nil)
    return if AccountFeatureGate.allows?(Current.account, key)

    nice = label || feature_label(key)
    error_response(
      ApiErrorCodes::FORBIDDEN,
      "Recurso \"#{nice}\" está desabilitado para este workspace.",
      status: :forbidden
    )
  end

  # Renders 422 when adding one more row to `scope` would exceed the cap.
  # `scope` may be an Integer (already-counted) or anything that responds
  # to `count`. nil cap = unlimited (always passes).
  def ensure_under_limit!(key, scope, label: nil)
    cap = AccountFeatureGate.limit(Current.account, key)
    return if cap.nil?

    current = scope.is_a?(Integer) ? scope : scope.count
    return if current < cap

    nice = label || limit_label(key)
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      "Workspace atingiu o limite de #{nice} (#{cap}).",
      status: :unprocessable_entity
    )
  end

  def feature_label(key)
    {
      'features.pipelines'         => 'Pipelines',
      'features.macros'            => 'Macros',
      'features.broadcast'         => 'Disparos em massa',
      'features.scheduled_messages'=> 'Mensagens agendadas',
      'features.followup'          => 'Follow-up automático',
      'features.csat'              => 'CSAT',
      'features.automations'       => 'Automações',
      'features.working_hours'     => 'Horário comercial',
      'features.mass_actions'      => 'Ações em massa',
      'features.reports'           => 'Relatórios',
      'ai.enabled'                 => 'Atendimento por IA',
      'channels.whatsapp_cloud'    => 'WhatsApp Cloud',
      'channels.whatsapp_uazapi'   => 'WhatsApp UAZAPI',
      'channels.whatsapp_evolution'=> 'WhatsApp Evolution',
      'channels.instagram'         => 'Instagram',
      'channels.facebook'          => 'Facebook',
      'channels.email'             => 'E-mail',
      'channels.webhook'           => 'Webhook',
      'channels.api'               => 'API'
    }[key.to_s] || key.to_s
  end

  def limit_label(key)
    {
      'limits.max_inboxes'             => 'caixas de entrada',
      'limits.max_agents'              => 'operadores',
      'limits.max_contacts'            => 'contatos',
      'limits.max_conversations_month' => 'conversas no mês',
      'limits.max_storage_mb'          => 'armazenamento (MB)',
      'ai.max_bots'                    => 'agentes de IA'
    }[key.to_s] || key.to_s
  end
end
ApplicationController.include_mod_with('Concerns::ApplicationControllerConcern')
