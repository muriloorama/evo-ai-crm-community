# frozen_string_literal: true

module Dashboard
  class FiltersBuilder
    DEFAULT_RANGE_DAYS = 30

    attr_reader :params

    def initialize(account: nil, params:)
      @params = params
    end

    def time_range
      @time_range ||= begin
        parsed_since = parse_datetime(params[:since])
        parsed_until = parse_datetime(params[:until])

        if parsed_since.present? || parsed_until.present?
          since_time = (parsed_since || DEFAULT_RANGE_DAYS.days.ago).beginning_of_day
          until_time = (parsed_until || Time.current).end_of_day
          if since_time > until_time
            since_time, until_time = until_time.beginning_of_day, since_time.end_of_day
          end
          since_time..until_time
        else
          DEFAULT_RANGE_DAYS.days.ago.beginning_of_day..Time.current.end_of_day
        end
      end
    end

    def applied_filters
      {
        pipeline_id: pipeline_id,
        team_id: team_id,
        inbox_id: inbox_id,
        user_id: user_id,
        contact_type: contact_type,
        since: time_range.begin.to_i,
        until: time_range.end.to_i
      }.compact
    end

    def conversation_scope(base_scope = nil, apply_time_range: true)
      scope = (base_scope || Conversation.all)
      scope = scope.where(created_at: time_range) if apply_time_range
      scope = scope.where(team_id: team_id) if team_id.present?
      scope = scope.where(inbox_id: inbox_id) if inbox_id.present?
      scope = scope.where(assignee_id: user_id) if user_id.present?
      scope = scope.joins(:pipeline_items).where(pipeline_items: { pipeline_id: pipeline_id }).distinct if pipeline_id.present?
      scope = scope.joins(:contact).where(contacts: { contact_type: Contact.contact_types[contact_type] }) if contact_type.present?
      scope
    end

    def reporting_events_scope(base_scope = nil)
      scope = (base_scope || ReportingEvent.all).where(created_at: time_range)
      scope = scope.where(inbox_id: inbox_id) if inbox_id.present?
      scope = scope.where(user_id: user_id) if user_id.present?
      scope = scope.joins(:conversation).where(conversations: { team_id: team_id }) if team_id.present?

      if pipeline_id.present?
        scope = scope.joins(conversation: :pipeline_items).where(pipeline_items: { pipeline_id: pipeline_id })
      end

      scope.distinct
    end

    def pipeline_items_scope(base_scope = nil)
      scope = (base_scope || PipelineItem.all).where(created_at: time_range)
      scope = scope.where(pipeline_id: pipeline_id) if pipeline_id.present?

      if team_id.present? || inbox_id.present? || user_id.present?
        scope = scope.joins(:conversation)
        scope = scope.where(conversations: { team_id: team_id }) if team_id.present?
        scope = scope.where(conversations: { inbox_id: inbox_id }) if inbox_id.present?
        scope = scope.where(conversations: { assignee_id: user_id }) if user_id.present?
      end

      scope
    end

    def pipeline_tasks_scope(base_scope = nil)
      scope = (base_scope || PipelineTask.all).where(created_at: time_range)
      scope = scope.joins(:pipeline_item)
      scope = scope.where(pipeline_items: { pipeline_id: pipeline_id }) if pipeline_id.present?

      if team_id.present? || inbox_id.present? || user_id.present?
        scope = scope.joins(pipeline_item: :conversation)
        scope = scope.where(conversations: { team_id: team_id }) if team_id.present?
        scope = scope.where(conversations: { inbox_id: inbox_id }) if inbox_id.present?
        scope = scope.where(conversations: { assignee_id: user_id }) if user_id.present?
      end

      scope
    end

    def messages_scope(base_scope = nil)
      scope = (base_scope || Message.all).where(created_at: time_range)
      scope = scope.where(inbox_id: inbox_id) if inbox_id.present?
      joins_applied = false

      if team_id.present? || pipeline_id.present? || user_id.present?
        scope = scope.joins(:conversation)
        joins_applied = true
        scope = scope.where(conversations: { team_id: team_id }) if team_id.present?
        scope = scope.where(conversations: { assignee_id: user_id }) if user_id.present?
      end

      if pipeline_id.present?
        scope = scope.joins(conversation: :pipeline_items).where(pipeline_items: { pipeline_id: pipeline_id })
        joins_applied = true
      end

      return scope unless joins_applied

      # Avoid DISTINCT messages.* on json/jsonb columns (PostgreSQL has no equality operator for json)
      deduped_ids = scope.unscope(:select, :order).reselect(:id).distinct
      (base_scope || Message.all).where(id: deduped_ids)
    end

    def csat_scope(base_scope = nil)
      scope = (base_scope || CsatSurveyResponse.all).where(created_at: time_range)
      scope = scope.where(assigned_agent_id: user_id) if user_id.present?
      joins_applied = false

      if team_id.present? || inbox_id.present? || pipeline_id.present?
        scope = scope.joins(:conversation)
        joins_applied = true
        scope = scope.where(conversations: { team_id: team_id }) if team_id.present?
        scope = scope.where(conversations: { inbox_id: inbox_id }) if inbox_id.present?
      end

      if pipeline_id.present?
        scope = scope.joins(conversation: :pipeline_items).where(pipeline_items: { pipeline_id: pipeline_id })
        joins_applied = true
      end

      return scope unless joins_applied

      deduped_ids = scope.unscope(:select, :order).reselect(:id).distinct
      (base_scope || CsatSurveyResponse.all).where(id: deduped_ids)
    end

    private

    def pipeline_id
      params[:pipeline_id].presence
    end

    def team_id
      params[:team_id].presence
    end

    def inbox_id
      params[:inbox_id].presence
    end

    def user_id
      params[:user_id].presence
    end

    # Limits dashboard aggregations to contacts of a specific lifecycle type
    # ("visitor" / "lead" / "customer"). Used by the "Clientes convertidos"
    # toggle to focus the dashboard on customers only.
    def contact_type
      value = params[:contact_type].to_s.downcase.presence
      return if value.blank?
      return unless Contact.contact_types.key?(value)

      value
    end

    def parse_datetime(value)
      return if value.blank?

      if value.to_s.match?(/\A\d+\z/)
        Time.zone.at(value.to_i)
      else
        Time.zone.parse(value.to_s)
      end
    rescue ArgumentError, TypeError
      nil
    end
  end
end
