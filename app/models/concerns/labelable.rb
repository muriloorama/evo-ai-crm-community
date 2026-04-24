module Labelable
  extend ActiveSupport::Concern

  UUID_REGEX = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i.freeze

  included do
    acts_as_taggable_on :labels
  end

  def update_labels(labels = nil)
    update!(label_list: normalize_labels(labels))
  end

  def add_labels(new_labels = nil)
    new_labels = Array(new_labels)
    combined_labels = labels + normalize_labels(new_labels)
    update!(label_list: combined_labels)
  end

  private

  # Accept either Label titles or UUIDs from the client and always persist titles,
  # since acts_as_taggable_on stores the raw string and the serializer resolves by title.
  def normalize_labels(labels)
    list = Array(labels).map { |value| value.to_s.strip }.reject(&:blank?)
    return list if list.empty?

    uuid_values = list.select { |value| value.match?(UUID_REGEX) }
    title_by_id = uuid_values.any? ? Label.where(id: uuid_values).index_by { |label| label.id.to_s } : {}

    list.map { |value| title_by_id[value]&.title || value }
  end
end
