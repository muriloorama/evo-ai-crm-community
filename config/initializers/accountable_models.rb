# Multi-account row-level scoping.
#
# Includes the `Accountable` concern into every model whose table gained an
# `account_id` column via `AddAccountIdToDataTables`. Including via an
# initializer keeps the list of scoped models in one place instead of
# sprinkling `include Accountable` across ~40 files.
#
# The concern installs a `default_scope` and a `before_validation` callback
# that reads `Current.account_id` — see `app/models/concerns/accountable.rb`.
#
# Not yet covered (follow-up):
#   * ActsAsTaggableOn::Tag / Tagging — managed by the gem, needs monkey-patch.
Rails.application.config.to_prepare do
  models = %w[
    AgentBot
    AgentBotInbox
    AutomationRule
    CannedResponse
    Channel::Api
    Channel::Email
    Channel::FacebookPage
    Channel::Instagram
    Channel::Line
    Channel::Sms
    Channel::Telegram
    Channel::TwilioSms
    Channel::TwitterProfile
    Channel::WebWidget
    Channel::Whatsapp
    Contact
    ContactCompany
    ContactInbox
    Conversation
    ConversationParticipant
    CsatSurveyResponse
    CustomAttributeDefinition
    CustomFilter
    DashboardApp
    DataImport
    Inbox
    InboxMember
    Integrations::Hook
    Label
    Macro
    Mention
    Message
    MessageTemplate
    Note
    Notification
    NotificationSetting
    Pipeline
    PipelineItem
    PipelineStage
    ReportingEvent
    ScheduledAction
    ScheduledActionTemplate
    Team
    TeamMember
    TelegramBot
    Webhook
    WorkingHour
    FollowUpRule
    FollowUpExecution
    TrackingSource
    CampaignInvestment
    MetaAdAccount
  ]

  models.each do |name|
    klass = name.safe_constantize
    next unless klass && klass < ActiveRecord::Base

    klass.include(Accountable) unless klass.include?(Accountable)
  end
end
