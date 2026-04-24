class Webhooks::FacebookFeedEventsJob < MutexApplicationJob
  queue_as :default
  retry_on LockAcquisitionError, wait: 1.second, attempts: 8

  def perform(change_value, page_id: nil)
    parser = ::Integrations::Facebook::FeedParser.new(change_value)

    unless parser.valid?
      Rails.logger.warn("FacebookFeedEventsJob: Invalid feed change payload: #{change_value}")
      return
    end

    channel = page_id.present? ? Channel::FacebookPage.find_by(page_id: page_id) : nil
    if channel.blank?
      Rails.logger.warn("FacebookFeedEventsJob: No channel found for page_id=#{page_id}")
      return
    end

    # Use comment_id as mutex key for comment events to prevent duplicate processing
    # For post events, use post_id
    mutex_key = if parser.comment_event?
                  format(::Redis::Alfred::FACEBOOK_COMMENT_MUTEX, comment_id: parser.comment_id)
                else
                  format(::Redis::Alfred::FACEBOOK_POST_MUTEX, post_id: parser.post_id)
                end

    with_lock(mutex_key) do
      Accountable.with_account(channel.account_id) do
        process_feed_change(parser, page_id)
      end
    end
  end

  private

  def process_feed_change(parser, page_id)
    if parser.comment_event?
      process_comment_event(parser, page_id)
    elsif parser.post_event?
      process_post_event(parser)
    else
      Rails.logger.warn("FacebookFeedEventsJob: Unsupported item type: #{parser.item}")
    end
  end

  def process_comment_event(parser, page_id)
    case parser.verb
    when 'add'
      ::Integrations::Facebook::CommentCreator.new(parser, page_id: page_id).perform
    when 'edited'
      ::Integrations::Facebook::CommentUpdater.new(parser, page_id: page_id).perform
    when 'remove'
      ::Integrations::Facebook::CommentRemover.new(parser, page_id: page_id).perform
    else
      Rails.logger.warn("FacebookFeedEventsJob: Unsupported comment verb: #{parser.verb}")
    end
  end

  def process_post_event(parser)
    # For now, we only process comments, not post events themselves
    # Post events can be handled in the future if needed
    Rails.logger.info("FacebookFeedEventsJob: Post event received (item: #{parser.item}, verb: #{parser.verb}) - not processing")
  end
end

