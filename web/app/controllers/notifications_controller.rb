# frozen_string_literal: true

# A person's own notifications: the bell in the header opens this list.
class NotificationsController < AuthenticatedController
  def index
    @pagy, @notifications = pagy(mine.newest, items: 30)
    @unread = mine.unread.count
  end

  # Opening a notification marks it read and goes to what it is about.
  def show
    notification = mine.find(params[:id])
    notification.update(read_at: Time.current) unless notification.read?
    redirect_to(internal_path(notification.url) || notifications_path)
  end

  def read_all
    mine.unread.update_all(read_at: Time.current, updated_at: Time.current)
    redirect_to(notifications_path, notice: 'All caught up.')
  end

  private

  def mine
    Notification.where(user_id: Current.user.id)
  end

  # Only same-site paths: a stored URL is never an open redirect.
  def internal_path(url)
    url if url.to_s.match?(%r{\A/[^/\\]})
  end
end
