# frozen_string_literal: true

# The Next thing to do bar under the top bar (NextThings). It loads into its own frame after the page, so it never
# slows a page down. Ops mode turns it into a guided queue: one item at a time with Open, Done, Snooze and Skip.
# Ops mode and skips live in this browser session; Done and Snooze are saved per person.
class NextThingsController < AuthenticatedController
  before_action -> { response.headers['Cache-Control'] = 'no-store' }

  # GET /next_thing
  def show
    @items = NextThings.for(Current.user)
    @ops = session[:ops_mode] == true
    skipped = Array(session[:ops_skipped])
    @queue = @ops ? @items.reject { |item| skipped.include?(item[:key]) } : @items
    # Skipped to the end of the list: start again from the top rather than show "all clear".
    if @ops && @queue.empty? && @items.any?
      session[:ops_skipped] = []
      @queue = @items
    end
    @current = @queue.first
    @position = @current ? @items.index(@current).to_i + 1 : 0
    render layout: false
  end

  # POST /next_thing/done, /next_thing/snooze { key }
  def done = dismiss('done')
  def snooze = dismiss('snooze')

  # POST /next_thing/skip { key }: ops mode moves on to the next item (this session only).
  def skip
    session[:ops_skipped] = (Array(session[:ops_skipped]) + [params[:key].to_s.first(200)]).uniq.last(50)
    redirect_to next_thing_path, status: :see_other
  end

  # POST /next_thing/mode { ops: 1|0 }
  def mode
    session[:ops_mode] = params[:ops].to_s == '1'
    session[:ops_skipped] = []
    redirect_to next_thing_path, status: :see_other
  end

  private

  def dismiss(kind)
    NextThings.new(Current.user).dismiss!(params[:key].to_s, kind)
    redirect_to next_thing_path, status: :see_other
  end
end
